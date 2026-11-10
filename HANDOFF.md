# GlassWeave: implementation handoff for Claude

Prepared 2026-11-08 as a plan. Since then the `implement/milestone-1` branch
has gained the v0.1 pre-alpha candidate: the Swift package, the UIKit
laboratory, the test suites, a committed clean-consumer check, and a CI
workflow that has not run on GitHub. Nothing is released. GW-09's
physical-device qualification and the other device-dependent items are still
open; [the task checklist](tasks/todo.md) records what is verified. The rest
of this page is the original handoff. The user deliberately reserved
implementation for Claude.

## Pick up here (2026-11-10, after the glass-beyond, interaction, polish, Metal 4, presence, two clean rounds and the capability round GW-30 to GW-34)

**Capability round (VERIFY-ROUND5, 2026-11-10): GW-30 to GW-34 are built, merged and checked.** Read this block first;
the older blocks below it still describe the earlier rounds.

- *Branches.* `implement/glass-beyond` holds everything: GW-30 (`ebdb1cc`, overlay mode), GW-34
  (`0a8dd3d`, touch on frost and fill) and the real merge commit `0bd1123` of `implement/glass-host`
  (GW-32 `da82d7b` springs and proximity merge, GW-33 `e8334aa` tilt, GW-31 `b67b519` snapshot source). The one
  conflict was `docs/interaction.md` (both titles kept). `GlassWeave-host` (the worktree folder) still exists;
  remove it after review. The branch was pushed to `origin` (`implement/glass-beyond`, fast-forward, nothing else: not `main`, no tag, not `implement/glass-host`) at the end of VERIFY-ROUND5 because the user said so in chat; the commit that carries this note is the pushed tip.
- *What exists (experimental, unreleased, off by default).* **Overlay mode** (`GlassRenderer.Mode.overlay`, a separate
  overlay shader): a transparent surface that tints, lights, glows and shades live UIKit content; it cannot bend or frost
  it. **`UIKitSnapshotSource`**: a pooled snapshot of a UIKit region as a background frame, so the custom glass can bend and
  frost real, static UI (refreshed on demand). **`PanelSpring`** and **`GlassProximityMerge`**: an interruptible frame spring
  and merging by proximity with hysteresis, pairs and clusters. **`GlassMotionSource`** (injected and Core Motion) and
  **`GlassTiltLight`**: a small low-passed tilt of the light. **Touch on frost and fill**: two new pipeline variants
  (`touchedFrosted`, `touchedFilled`). Design notes: [overlay](docs/overlay.md), [snapshot](docs/snapshot.md),
  [interaction](docs/interaction.md). Lab pages and launch arguments: the README's table (`-lab.overlay`, `-lab.snapshot`,
  `-lab.drag`, `-lab.tilt`, `-lab.touch.kind`).
- *Verification (merged tree, `xcresulttool` counts, one job after the other; Xcode MCP could not open a workspace, so `xcodebuild`).*

| Destination | Result |
| --- | --- |
| Package scheme, My Mac | 214 passed, 0 failed, 0 skipped (`xcresulttool`: 211 plus 3 tests in the two Swift Testing runs) |
| Package scheme, iPhone 18 Pro simulator (iOS 27.2) | 297 passed, 0 failed, 2 skipped of 299 (the two Metal 4 comparison tests) |
| All lab UI tests, iPhone 18 Pro simulator | 50 results, 49 passed, 0 failed, 1 skipped (the iPad-only two-scene test); the gallery dark audit passed again, unexplained |
| Studies and versus smoke, iPad Pro 13-inch (M5) simulator | 2 passed, 0 failed |
| `scripts/consumer_check.sh` at `f0c6604`, My Mac | passed (one pin at that revision, the consumer test passed) |

  All eleven frozen-baseline suites (`GlassBaselineGW12`, `GW13`, `GW20` to `GW25`, `GW28`, `GW30`, `GW34`) pass on both package
  destinations. The old pages were pixel-compared with a build of the parent `87dda27`: compare (three backdrops), lens, chrome,
  merge, three studies, the paper desk, the versus screen and the paused main screen are identical; the animated shapes, vessel and amber
  pages and the frost page differ only within the clock's own noise (parent against parent differs as much); the Touch page's
  glass is identical. One small lab fix was made here: the Drag, Tilt and Touch pages drew
  their own button labels in white, unreadable on the opaque Reduce Transparency sheet in light mode (the Touch page had it since
  GW-12); they now use the system label color under that setting (not covered by a test).
- *Visual verdict per page, simulator at 3x beside the real `UIGlassEffect` twin (crops: `docs/evidence/captures/gw-verify5-*`).*
  **Overlay:** works and is clean (thin rim, soft shadow, no streak, band or grain), and the pooled light along the capsule is
  calm and something native cannot show; but the list's text stays crisp under it and runs through the capsule's label on the dark
  page, where native frosts it, and the light bar reads as a milky veil. **Over real UI:** works; an even frost and a thin
  rim over a snapshot of real rows; native is lighter, keeps faint text shapes and has a brighter rim; a white glyph under the dark
  page's left end leaves a pale smudge with a faint inner arc at 5x; static, a full-screen refresh took about 41 ms against a 33 ms
  bound. **Drag:** works; a smooth neck and no seam, close to Apple's container merge, clear with a thin rim where Apple's merged
  body is a flat gray plate on black. **Tilt:** works; the light moves the rim and the shadow (clock off once settled); the pill and
  the round button shift only faintly, and the chrome ring shows the light but its pearly double bands read as the soap-bubble ring the
  user does not want (an opt-in look from before). **Touch on frost and fill:** works; a soft pool on the frost, a pale light on the
  glass above the liquid (the liquid unchanged), no ring, smear or ghost; the round vessel (an earlier look) reads as an orange lamp in
  a gray ring. No new bend is noticeable as a bend at normal size. Native's twin is idle in the simulator.
- *Still open from this round.* A scrim or legibility control for text under an overlay panel; the snapshot capsule's smudge and
  arc; `PanelSpring`'s velocity carry-over has no trace test; the snapshot's full-screen refresh is over its bound; every device
  item (the Core Motion source, feel, battery, cost, a finger on frost and vessels, live VoiceOver); the skipped test groups; the one
  combined M5 characterization run; CI has never run on GitHub; the three known flaky tests below. The 60 MB of captures
  that the build agents committed for these tasks are in history; do not add more full-page captures.

**Earlier state (before the capability round).** Where the text below says nothing is pushed, that was true then: the remote then held `implement/glass-beyond` at `46d6758`.

**Branches.** Nothing is merged into `main` and nothing is tagged; see the capability-round block above for what was pushed.

- `implement/milestone-1`: the v0.1 candidate, GW-01 to GW-10.
- `implement/glow`: that candidate plus the glow work, GW-14 and GW-17 to GW-20.
- `implement/glass-beyond`: **continue here.** The glow branch plus GW-21 to GW-29,
  the REFINE and ENHANCE-LOOK looks, the amber vessel, GW-12 (touch response),
  GW-13 (merging), GW-15 (the SwiftUI adapter), the POLISH pass (subtle, blended bends)
  and GW-11 (the Metal 4 submission experiment and its decision). The vessel work, GW-15
  and GW-11 were built on `implement/glass-host` and joined with real merge commits.
- `implement/glass-host`: fully merged into `glass-beyond` twice (GW-11 is the last commit of the first
  round, merged by `59750fa`; GW-31, GW-32 and GW-33 by `0bd1123`). Its sibling worktree folder (`GlassWeave-host`) still exists next to the main
  checkout and was not removed; remove it after review.

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
[presentation](docs/presentation.md), [studies](docs/studies.md),
[interaction](docs/interaction.md) and [swiftui](docs/swiftui.md) for the design.

- GW-21 light fields; GW-22 thick lens, dispersion and inlays; GW-23 light model;
  GW-24 frost (pyramid and shader); GW-25 shadows and caustics; GW-26 freeform shapes;
  GW-27 non-blocking presentation and quality tiers (closes GW-04 item 3); GW-28 liquid
  and gel fill (the curved amber vessel); GW-29 four studies and the Apple vs GlassWeave
  screen.
- GW-12 touch response: a soft finger light, one travelling ring that bends the backdrop by
  at most `ripple x 8` points, a rim gleam; `GlassTouchObserver` takes no touch from native
  controls; the effect clock stops when the touch settles. GW-13 merging: two custom surfaces
  become one blob panel under `SurfaceTransition`'s interruptible spring, so every effect
  follows the merged outline. GW-15: the optional `GlassWeaveSwiftUI` product (`GlassSurface`),
  which owns no rendering; the core gained one read-only SPI, `GlassRendererCensus`, that
  counts renderers.
- POLISH (the user's feedback "the bends are way too visible, not well blended"): the cause
  was the lens falloff, which climbed to its peak within a pixel of the rim and had a kink
  where the bevel ended (stretched dots on a grid, a smear on a soft backdrop, a start line).
  `GlassLens.softness` (opt-in, default 0) gives the bend a quintic window and a soft ceiling;
  the lab's lenses use it with small offsets and faint fringes (`RefinedLook.blend`). Touch is
  now a barely-there pool, ring (at most about 2.6 points of displacement) and gleam; the
  chrome ring is larger with prismatic glints; `GlassFill.richness` (opt-in) adds a restrained
  surface window and warm sheet edges to the liquid.
- GW-11, the Metal 4 experiment (package level, My Mac only, compiled out for the simulator, no
  host uses it, no public API): `Metal4Renderer` submits the GW-09 workload through
  `MTL4CommandQueue` with the same shader library, pipelines and records as the conventional
  path; the agreement test shows 0 of 12,648,528 bytes differing in each of four reference
  cases. The comparison harness, the timing result and the decision are in
  [the record](docs/decisions/metal-backend.md).
- Each task has one safety test (the new path off is byte-identical to a frozen copy of
  the previous shader; GW-15's is `AdapterLifecycleTests`, which counts renderers). Every other acceptance item that needs a further test, a CPU
  mirror, an M5 run or a device is unchecked in [the checklist](tasks/todo.md) with a
  reason (fast pass: not tested, device only, ...).

**Previous verification run (VERIFY-ROUND3, one batch on the merged tree `59750fa`, `xcresulttool` counts; the latest is under "Presence pass" below).**

Xcode MCP could not open a workspace here, so everything used `xcodebuild`; counts are from
`xcresulttool`.

| Destination | Result |
| --- | --- |
| Package scheme, My Mac | 211 passed, 0 failed, 0 skipped. (The first attempt did not run any test of `GlassWeaveTests`: xctest could not load the bundle, "executable couldn't be located", an infrastructure error right after the merge rebuild; the whole scheme was rerun once and passed.) |
| Package scheme, iPhone 18 Pro simulator (iOS 27.2) | 292 passed, 0 failed, 2 skipped (the two Metal 4 tests, which skip on the simulator with a stated reason) |
| All lab UI tests, iPhone 18 Pro simulator | 50 results: 46 passed, 1 failed (the gallery dark audit below), 3 skipped (two dark audits that skip because the system appearance does not reach the app, and the iPad-only two-scene test) |
| Studies and versus smoke, iPad Pro 13-inch (M5) simulator | 2 passed, 0 failed |
| `scripts/consumer_check.sh` at the merged commit, My Mac | passed |

All nine frozen-shader safety suites (`GlassBaselineGW20` to `GW25`, `GW28`, `GW12` and `GW13`)
pass on both package destinations; GW-15's `AdapterLifecycleTests` passes on the iPhone one. The
Metal 4 agreement test passes on My Mac (0 of 12,648,528 bytes differ in each of four cases).
The previous round (VERIFY-ROUND2) recorded 208 passed and 1 failed on My Mac and 292 on the
iPhone package run; `FrameLifecycleTests` "100 hide and show cycles..." passed this time.

**GW-11, the Metal 4 decision (the one quiet timing run, My Mac, Apple M3 Max, Release).**
Metal 4 submission was not better than the conventional control: pooled over 3 runs of 60 s per
window (10,800 frames per arm and case), CPU encode p95 was 0.235 against 0.307 ms (panel) and
0.243 against 0.293 ms (lens), and GPU p95 0.964 against 1.244 ms and 1.327 against 1.449 ms;
the p50 values were equal within 5 percent. The rule needed a p95 lower by 20 percent and 0.20
ms in every run, so **the conventional path stays the only shipped backend** and
`Metal4Renderer` stays a package-level characterization arm that no host reaches. It is one
Mac, not a device. Record: [metal-backend](docs/decisions/metal-backend.md#decision); raw report
and conditions: [metal4-quiet-run](docs/evidence/metal4-quiet-run.md).

**The visual state after POLISH (simulator, merged tree, the twelve pages were pixel-compared
with the committed captures: identical outside the status-bar clock).** Every bend is now subtle
and blends from the rim into the flat middle with no start line, kink or smear; the touch is a
soft pool. Still short: see the verdict below.

**Still open.**

1. Every physical-device item: the GW-09 qualification, every effect's cost and
   shimmer, the GW-27 120 Hz trace, a live VoiceOver pass.
2. One combined M5 characterization run for all effects and tiers; no cost claim exists. (The
   machine here reports itself as Apple M3 Max, not M5; the GW-11 run used what the device reports.)
3. The skipped test groups: CPU-mirror comparisons for the lens, dispersion, light
   model, frost, shadows, shapes and fill; the 1,000-background legibility sweeps; the
   accessibility audit, largest-text and right-to-left runs for the studies; the
   controlled-clock UIKit tests; the numeric tests for the refined and enhanced terms.
4. The gallery's dark accessibility audit (pre-existing) and two timing-sensitive tests, below.
5. CI has never run on GitHub.
6. GW-16 has not started. GW-11 is built and decided for My Mac; a device run of the same
   harness is open (device only), as are Metal 4 encodings of frost, grounding, shapes, fills and
   touch, which exist only if a device run ever reopens it. GW-12, GW-13 and GW-15 are built with their one safety
   test each; open for them: a finger on a device (tap, drag and cancel through the observer),
   their cost, frost and fill panels under touch (built in GW-34, simulator only), two simultaneous
   touches (implemented, only looked at pinned), merging with frost, fill or touch on the
   merged panel, a real-scene visibility test and a live VoiceOver pass through the adapter, an
   Xcode preview, and the CPU-mirror and controlled-clock tests the fast pass skipped.
7. Visual gaps against the references: see [the plan](tasks/plan.md).

Checklist counts, ticked/open per section of `tasks/todo.md` after the Presence round (140 ticked, 145 open
in all, counted as lines starting `- [x]` and `- [ ]`; every unticked task box has a reason on its line, while the 13 open lines under the six
Checkpoint headings are the plan's original gates, which wait on the physical-device qualification
and carry no reason of their own): GW-01 2/1; GW-02 2/1; GW-03 3/0; Checkpoint A
0/2; GW-04 3/0; GW-05 3/0; GW-06 2/1; Checkpoint B 0/2; GW-07 3/0; GW-08 2/1; GW-09 0/3; Checkpoint C
0/3; GW-10 2/1; Checkpoint D 1/1; GW-11 7/2; GW-12 4/5; GW-13 8/3; Checkpoint E 0/2; GW-14 6/1; GW-15
2/1; GW-16 0/3; Checkpoint F 0/3; GW-17 5/0; GW-18 3/0; GW-19 3/0; GW-20 3/0; GW-21 2/11; GW-22 1/16;
GW-23 1/10; GW-24 4/16; GW-25 1/7; GW-26 1/7; REFINE 6/3; ENHANCE-LOOK 6/3; POLISH 9/3; PRESENCE 13/3; GW-27 3/5;
GW-28 1/10; GW-29 2/7; Merge 4/1; VERIFY-FINAL 7/2; VERIFY-ROUND2 7/2; VERIFY-ROUND3 8/3.
After the capability round (191 ticked, 166 open in all, counted the same way): GW-30 3/1; GW-31 2/1; GW-32 3/1;
GW-33 2/1; GW-34 2/1; VERIFY-ROUND5 7/4 (every unticked line has its reason).

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
  1 of 7 simulator runs and 1 of 4 My Mac runs, passes alone 3 of 3). It failed again
  in VERIFY-ROUND2's one full My Mac run and passed alone 3 of 3. It passed in VERIFY-ROUND3's
  Mac and iPhone package runs.

**Visual verdict (simulator captures `docs/evidence/captures/gw-final-*`, compared with a real
`UIGlassEffect` on the same backdrop and, locally, with the four private references).**

- *Better than Apple's.* Hues inside the material: the pill is a clear lens body with a deep
  pink-to-violet pool along its bottom, where native glass takes one flat tint. A lens bevel with
  real dispersion and a frost with a clear center (the shelf capsule over a rainbow). A polished
  banded chrome ring with glints, freeform pebbles, and a curved luminous liquid in thick smoky
  glass (Amber). It stays in the same family as native: one light, a thin rim, soft shadows,
  calm color, no bubbles or neon.
- *Still short of Apple's.* No live bending of whatever is behind it (the backdrop must be
  supplied), no system integration, and every look is tuned by eye per backdrop, where native
  adapts to any content.
- *Touch, merging and SwiftUI (VERIFY-ROUND2, simulator only; nobody has felt any of it on a device).*
  Touch: native interactive glass gathers a light under the finger; ours adds a ring that really
  bends what is behind it (the pinned dot-grid capture shows the lattice bending) and a rim gleam
  that leans toward the finger, but at the standard strength over a busy backdrop it is subtle in
  a still frame (it reads at 2x), and its timing and feel are untested with a finger. Merging: two
  surfaces become one pill with a smooth neck under a spring, and lens, light, frost and shadow
  follow the merged outline; it stays clear with a thin rim where the system container's merge
  reads as one flat tinted body in the twin. It is limited to circles and capsules, is driven by
  the app (no merge by proximity), and the merged pill looks dimmer on the dark page than on the
  colorful one. SwiftUI: the panel sits behind real SwiftUI controls and reads as the same family
  as the native capsule above it, but the app must supply the backdrop, a Metal command queue and
  the panel frames, where `.glassEffect` just works over anything.
- *Still short of the references.* Reference 1 (liquid): ours is smoother and more diffuse, with
  no white-hot sheet edges, no specular spot on the liquid's own curved surface, no parallax and
  no gray studio reflections on the rim (the last on purpose). Reference 2 (frosted capsule):
  the blur is gentler and the fringes subtler. Reference 3 (ring): ours is a smaller
  steel-silver ring with fainter prismatic glints than the chunky polished chrome. Reference 4
  (lens pill): the bend at the edges is weak over soft backdrops, the pooled glow is quieter, and
  the dome button sits inside the pill instead of overlapping its end.

**Visual verdict after POLISH (VERIFY-ROUND3, the merged tree, iPhone 18 Pro simulator, each page
looked at beside a real `UIGlassEffect` where the page has one).**

- *Improved.* The bends are quiet and blended. On the Focus pill, the Camera pearl and the Open Air
  shelf the rim shows no start line, kink, smear or stretched petal; the bevel reads as a thin crisp
  rim over an even body; the dispersion is faint; the touch page is a soft pool with no visible ring.
  Next to the native capsules the refined glass is calmer and stays in the same family (one light,
  a thin rim, soft shadows), with hues inside the material (the pill's pink-violet pool, the
  shelf's clear center over a rainbow) that native glass cannot show.
- *Still short.* The restraint costs presence: on the Apple vs GlassWeave page over the orbs, the
  refined capsule and the rounded rectangle read as a clear, slightly gray panel, while the native
  one shows a stronger, more colorful edge refraction and a livelier body; the thick-lens capsule
  with its inlaid dome is nearly flat. A high-contrast edge is still visibly pulled when you look
  closely: at the right cap of the refined capsule on that page the red orb's edge bends about
  4 points inward inside the bevel and leaves a small gray wedge (faint at normal size, plain when
  zoomed). The liquid vessel's contour sheets read as topographic rings rather than one clean gel.
  On the paper desk page two lab captions overlap (a lab layout flaw, not the glass). Nothing
  here was felt with a finger or seen on a device. (The Presence pass below fixed the cap wedge,
  the vessel rings and the captions, and narrowed, but did not close, the presence gap.)

**Presence pass (PRESENCE, then VERIFY-ROUND4; experimental, unreleased; iPhone 18 Pro simulator
and My Mac only).** `GlassLighting.presence` (0...1, default 0, refined look only) makes the
glass livelier through color and light and adds no bend: the body picks up the backdrop softly
(scaled by a flatness gate), lifts without graying, the inner edge glows in the backdrop's hue
on the lit side, the far side is deeper, an inlaid dome gets a shade; a plain rim refraction is
feathered to 0 at the outline (never above its old value), which removed the cap wedge. The lab
applies it through `RefinedLook` (0.85, a lighter tint: the gray cast came from a gray tint
mixed in linear light), the amber vessel is one clean gel (two soft sheets), the paper desk
captions no longer overlap. Reduce Transparency and Increase Contrast set it to 0 in
`GlassAccessibilityPolicy`; presence 0 draws the previous bytes (the frozen-baseline suites
pass unmodified). Notes: [glass-optics](docs/glass-optics.md#presence-a-livelier-body-and-edge-with-no-extra-bend-presence),
[studies](docs/studies.md#presence-pass-presence-and-its-check-experimental-unreleased).

- *The independent check found a defect and fixed it.* Both builds (`67bf9cb` and `1915c8b`)
  were built fresh and captured on 23 pages with the same arguments, and on the dot grid,
  checkerboard and ribbons backdrops. The first presence build left a lattice of ghost copies
  over a dot grid and a checkerboard (13 sparse samples are not an average across an edge), and
  a pale second image of small colored dots under the thick lens (the paper desk marble: the
  pickup pulled in the undisturbed backdrop). A flatness gate on the pickup, and on the glow's
  color and strength, removed both (`Glass.metal`; captures `gw-presence-verify-ghost-*`). The
  committed captures of the nine changed pages were replaced.
- *Bends: not more visible in geometry.* No lens, offset, dispersion or touch value was
  changed; the only refraction edit is a factor of at most 1. On a checkerboard the checker
  edges inside the glass agree with the previous build within 0.3 px and the rim shapes look
  alike (`gw-presence-verify-bend-checker-*`). The same bend reads with about 19 percent more
  contrast on a black and white pattern (50 to 230 against 64 to 215 levels of luma), because
  the old gray haze is gone; on smooth backdrops, where the lab's pages sit, it is not visible.
- *Presence next to native glass: narrowed, not closed.* Over the orbs the refined capsule,
  circle and rounded rectangle keep their colors (a red orb stays a saturated red), carry a
  thin lit rim and a deeper far side, and the thick-lens capsule reads as thick glass with a
  visible dome; the Focus pill and the amber vessel are the best pages. The native body is
  still more present as a material (frosted, with a stronger hairline); ours stays clear. On
  the paper page a refined panel reads as a soft cushion more than as glass, and on the
  charcoal page the body is darker than the native one. Not tested: text-heavy backdrops (a dot
  grid, a checkerboard and colored dots on paper stood in), a device.
- *Increase Contrast, pre-existing:* a few faint bright dashes sit on the top edge of the
  refined rounded rectangle where the cyan orb meets it (they are in the previous build too).

| Destination (final tree, `xcresulttool`) | Result |
| --- | --- |
| Package scheme, My Mac | 211 passed, 0 failed, 0 skipped |
| Package scheme, iPhone 18 Pro simulator | 292 passed, 0 failed, 2 skipped (the two Metal 4 tests) |
| All lab UI tests, iPhone 18 Pro simulator | 50 results: 49 passed, 0 failed, 1 skipped (the iPad-only two-scene test); the known gallery dark audit passed this time, unexplained, nothing changed for it |
| Studies and versus smoke, iPad Pro 13-inch (M5) simulator | 2 passed, 0 failed |
| `scripts/consumer_check.sh` at the committed fix `72d9e41`, My Mac | passed (one pin at that revision, the consumer test passed) |

**Clean pass (CLEAN, then VERIFY-CLEAN; experimental, unreleased; iPhone 18 Pro simulator and My Mac
only).** The user: "Apple's implementation is way cleaner than ours ... match Apple's, but keep the
glow." `GlassLighting.clean` and `GlassParameters.dither` (both opt-in, both off by default and
byte-identical when off) give the refined rim one smooth gradient from the outline (the doubled
inner line, the dark crease and the slab notch are gone), soft wide chrome bands, a static
triangular dither on every pixel and shadow (the ordered cross-hatch is gone), a smooth Increase
Contrast polarity and smooth glow and light palettes; the lab uses both on every refined page
and has a text-heavy backdrop page. Notes: [glass-optics](docs/glass-optics.md#clean-pass-match-the-system-glasss-cleanliness-clean),
[studies](docs/studies.md#clean-pass-and-its-independent-check-clean-verify-clean-experimental-unreleased).

- *The independent check* built the pass and its parent (`9070250`) fresh and captured 28 pages
  (plus checkerboard, dots, Increase Contrast and Reduce Transparency pages) with the same
  arguments, then cropped at 2x to 16x beside the real `UIGlassEffect` twin. Verdicts: the compare
  pages, pill, shelf, lens, shapes, merge, touch, glow gallery and versus are clean; the pearl and
  chrome rings, the vessel, the paper desk, frost and light fields are mostly clean (see the next
  bullet). The doubled rim line, the cross-hatch and the thin chrome stripes are gone on every page
  (before and after crops: `gw-verify-clean-*`); Increase Contrast's dashes at the cyan orb's edge
  are gone; the glows (gallery, light fields, the pill's pooled glow, the vessel's liquid, merge,
  touch, the versus gradient) still show their hues, with no banding at 3x to 4x contrast.
- *Bends: unchanged.* The displacement code is not in the pass's shader diff, and on a checkerboard
  the squares' edges inside the glass are pixel-identical before and after. The bend is still
  visible as a bend on a checkerboard at the bevel, and the paper desk's lens pill still turns small
  dots into eggs; those are the lens values, not this pass.
- *Still open (first pass; items 1, 2 and 4 and most of item 3 were fixed by clean pass 2 below).* (1) The Light fields page's four-corner field has a diagonal crease at each inner
  corner (the distance-to-outline medial axis; the same before the pass; not fixed, a smoothed
  distance in `gw_light_emitter` behind `clean` would do it). (2) The chrome and pearl rings have a
  hard one-pixel step between the dark outer band and a bright lip (a staircase at 8x to 16x, not
  visible at 1x to 3x; same before). (3) Our body carries a static grain of about one 8-bit step
  (native 0.1 to 0.2 levels of neighbour difference, ours 0.8 to 1.2), invisible below about 4x,
  and the rim is a gradient about ten points wide where the native one is a thin line. (4) Under
  Reduce Transparency the opaque panel lost its soft gray inner edge shade (it is a flat panel
  with a crisp edge; on paper the hairline stays). (5) The fine ring detail and the glints are
  opt-in finishes the native glass does not have.
- *One retune in this check:* the frost page's capsule (dispersion 1 to 0.3, soft window): two
  background stars at its rim were squeezed and fringed into rainbow dashes.

| Destination (final tree, `xcresulttool`) | Result |
| --- | --- |
| Package scheme, My Mac | 211 passed, 0 failed, 0 skipped |
| Package scheme, iPhone 18 Pro simulator | 292 passed, 0 failed, 2 skipped (the two Metal 4 tests) |
| All lab UI tests, iPhone 18 Pro simulator | 50 results: 48 passed, 1 failed, 1 skipped (the iPad-only two-scene test). The failure, `PresentationUITests.testHeldDrawablesNeverStallTheMainThreadAndTheRequestDrawsOnRelease`, timed out once while `scripts/consumer_check.sh` ran on the same Mac; it passed 3 of 3 alone. The known gallery dark audit passed again (unexplained, nothing changed for it). |
| Studies and versus smoke, iPad Pro 13-inch (M5) simulator | 2 passed, 0 failed |
| `scripts/consumer_check.sh` at `71ee228`, My Mac | passed (one pin at that revision, the consumer test passed) |

**Clean pass 2 (CLEAN-2, then VERIFY-CLEAN-2; experimental, unreleased; iPhone 18 Pro simulator and My Mac
only).** The user: "I want to match Apple's, but at the same time have those glow capabilities that Apple
cannot do." The default clean rim is now a thin crisp hairline (a Gaussian of the exact distance to the
outline, about 0.5 pt wide at half maximum, down to 10 percent of its peak 1.3 pt in); the wide soft rim of the
first pass is the opt-in `GlassLighting.softRim` (0...1, default 0, packed above the clean level in
`lighting.tint.w`; the lab's `-lab.softRim 1`). The same pass smoothed the four-corner light field's
diagonal crease, the ring lens's hard step, the grain of a flat body (the triangular dither now goes only
where the shader draws a gradient) and the opaque panel's edge shade under Reduce Transparency. Notes:
[glass-optics](docs/glass-optics.md#clean-pass-second-round-a-thin-crisp-rim-five-fixes-clean-2),
[studies](docs/studies.md#clean-pass-2-and-its-independent-check-clean-2-verify-clean-2-experimental-unreleased).

- *The independent check (VERIFY-CLEAN-2)* built the pass and its parent (`887103b`, from `git archive`)
  fresh and captured 38 pages with the same launch arguments at 3x, then cropped at 2x to 24x beside the real
  `UIGlassEffect` twin (`gw-verify-clean2-*`). Every page is clean: no streak, stripe, band, step, doubled
  line, dash or crease that the native twin does not also show, and the native body shows 8-bit contour
  terraces at 6x to 24x contrast where ours shows a smooth gradient. Rim, charcoal top edge: native peak +50
  over the body, half maximum 2.8 px, 10 percent at 4 px; ours before +57, 2.7 px, 8 px; ours after +53,
  2.5 px, 4 px (the same definition for both). On the light page the dark line is 26 levels deep and 1 px wide at
  the top (native 25, 2 px).
- *Bends: not raised.* Every dark/light edge of a checkerboard inside the glass sits within 0.5 px (almost all
  under 0.1 px) of where it was before the pass, on the lens page and on the compare page; the glow
  capabilities (the gallery, light fields, the pill's pooled glow, the vessel's liquid, frost, merge, touch)
  are smooth at 3x to 4x contrast, and `-lab.softRim 1` reproduces the first pass's rim within 2 to 4 levels.
- *Still open.* (1) On mid-tone backdrops (orbs) the lip is fainter than the native one (+20 against +50 levels). (2) The
  native side lines (near black on charcoal, 82 levels on paper) are not matched, and ours is darker on
  charcoal (body 48 against 62). (3) The grain on a flat body is two times the native level (rms 0.34 and 0.49
  against 0.17 and 0.25). (4) The dome button's outline has a one-pixel staircase at 12x. (5) No tests for the
  new terms, no CPU mirror, no device, no M5 cost of the thirteen extra distance evaluations. The first pass's
  other open items (the ring step, the crease, the opaque panel's edge shade) are fixed.

| Destination (clean pass 2, `xcresulttool`) | Result |
| --- | --- |
| Package scheme, My Mac | 211 passed, 0 failed, 0 skipped |
| Package scheme, iPhone 18 Pro simulator | 292 passed, 0 failed, 2 skipped (the two Metal 4 tests) |
| All lab UI tests, iPhone 18 Pro simulator | 50 results: 49 passed, 0 failed, 1 skipped (the iPad-only two-scene test); the known gallery dark audit, the frame-lifecycle cycles and the held-drawables test all passed, nothing was rerun |
| Studies and versus smoke, iPad Pro 13-inch (M5) simulator | 2 passed, 0 failed |
| `scripts/consumer_check.sh` at `7517cfb`, My Mac | passed (one pin at that revision, the consumer test passed) |

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

- The new pages: `-lab.touch YES` (`-lab.touchBackdrop orbs|stage|grid`, `-lab.touch.pin
  "pill:0.3:0.55:0.18;round:0.55:0.5:0.12"` freezes synthetic touches, `-lab.touch.boost 2`,
  `-lab.touch.auto YES`), `-lab.merge YES` (`-lab.mergeBackdrop stage|orbs`, `-lab.merge.progress
  0.5`, `-lab.merge.auto YES`), `-lab.swiftui YES` (`-lab.swiftui.strength`, `-lab.swiftui.light
  NO`, `-lab.swiftui.quality balanced|minimal`).
- A real tap in the simulator: the `Claude_Code_iOS_Simulator` control tool taps in device
  points (402 x 874 on the iPhone 18 Pro); use a hold of about 0.15 s on a `UISwitch`, which
  ignores the tool's shortest tap.
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
