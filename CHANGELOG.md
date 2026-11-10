# Changelog

## Unreleased: glass beyond native (experimental, GW-21 to GW-29, GW-12, GW-13, GW-15, GW-11, POLISH, PRESENCE, CLEAN, CLEAN-2, GW-30 to GW-34, VESSEL, RING)

Requested by the user on 2026-11-09, on the branch `implement/glass-beyond`
(nothing merged into `main`, nothing tagged). Every API is experimental, every
new parameter is off by default and renders the previous shader's bytes when
off (frozen-shader readback tests), and the evidence is simulator and Mac
only. Design notes: [glass optics](docs/glass-optics.md),
[frost](docs/frost.md), [presentation](docs/presentation.md),
[studies](docs/studies.md), [interaction](docs/interaction.md),
[overlay](docs/overlay.md), [snapshot](docs/snapshot.md),
[the SwiftUI adapter](docs/swiftui.md).

### Added

- Overlay mode (GW-30): `GlassRenderer(commandQueue:mode: .overlay)`
  (`GlassRenderer.Mode`) draws each panel as premultiplied alpha with no
  background pass and no source, from a separate overlay shader
  (`gw_overlay_fragment`): tint, rim and edge light, glow, halo, interior,
  inner light and shadow, and a drop shadow outside the outline. A
  `GlassSurfaceView` made with it is transparent, needs no source and passes
  touches through. It cannot bend or frost what is behind it. The default opaque
  shader is untouched (frozen-shader readback test `GlassBaselineGW30Tests`).
- Snapshot source (GW-31): `UIKitSnapshotSource` captures a region of a UIKit
  view into a pooled `bgra8Unorm_srgb` frame (upright, opaque, on the renderer's
  queue) and hands it to the surface through `setSource`, so the custom glass can
  bend and frost real, static UI. Refreshed on demand, not live; every capture
  reports its measured draw and upload time. A full-screen refresh took about 41 ms
  on the simulator (the bound is 33 ms), a list-sized one 10 to 19 ms.
- Panel spring and proximity merge (GW-32): `PanelSpring` moves a frame on the
  effect clock and retargets in flight without touching the velocity;
  `GlassProximityMerge` maps the gap between two outlines (circle, capsule,
  rounded rectangle) to a 0...1 progress with hysteresis, tracks pairs and
  groups connected panels, and builds the merged blob panel.
- Tilt-driven light (GW-33): `GlassMotionSource` with `GlassCoreMotionSource`
  (unverified without a device) and `GlassInjectedMotionSource`, and
  `GlassTiltLight`, which maps gravity to a small azimuth and elevation offset
  through a low-pass filter; Reduce Motion pins the light.
- Touch on frost and fill (GW-34): a frosted panel and a filled vessel answer a
  touch with the same finger light, ring and rim gleam as other panels, through
  two new pipeline variants (`touchedFrosted`, `touchedFilled`, each for a
  rounded rectangle and a freeform shape). Panels without a touch, or with only
  one of frost, fill and touch, render the previous bytes (`GlassBaselineGW34Tests`).
- Lab pages Overlay, Over real UI, Drag and Tilt, and a Clear / Frost / Vessel
  control on the Touch page; launch arguments are in the README.

- Touch response (GW-12): `GlassTouch` (`GlassParameters.touch`, default
  `.none`, `.standard`), `GlassTouchPoint`, `GlassTouchState` (a pure function of
  the touch and the time), `GlassRenderer.setTouches(_:)` (up to two), a soft
  finger light, one travelling ring that moves the backdrop sample by at most
  `ripple x 8` points, and a rim gleam. `GlassTouchObserver` (a gesture
  recognizer that never recognizes, delays or cancels, so native controls keep
  their taps) and `GlassSurfaceView.beginTouch/moveTouch/endTouch/cancelTouch`.
  The effect clock stops when the touch settles. New records `GWTouchUniforms`
  (128 bytes) and `GWTouchPoint` (48), with size asserts in C and MSL.
- Merging two surfaces (GW-13): `GlassSurfaceMerge` (two surfaces, each a
  circle or capsule apart and merged; `blob(progress:)`), drawn as one blob
  panel through the GW-26 path so lens, light, frost, fill and shadow follow
  the merged outline; `GlassBlob.interiorSmoothness`, `GlassShape.Field.mergeProgress`,
  and `SurfaceTransition` (UIKit): an interruptible, reversible spring on the
  effect clock that settles to on-demand rendering and jumps under Reduce
  Motion. `GWShapeUniforms` keeps its 336 bytes (`depthSmoothness` takes the
  padding word).
- `GlassWeaveSwiftUI` (GW-15), a new optional library product: `GlassSurface`
  (a SwiftUI view over `GlassSurfaceView`), `GlassSurfaceConfiguration` and
  `GlassSurfaceContent`. Configuration updates reach the UIKit host without
  recreating the renderer; a new view identity builds a new one; the
  accessibility policy is the host's. It compiles to nothing on macOS. The
  core gained one read-only SPI (`@_spi(Census) GlassRendererCensus`) that
  the example and the test use to count renderers. The core and UIKit
  products do not import the adapter.
- Subtle, blended bends (POLISH, after the feedback "the bends are way too
  visible, not well blended"): `GlassLens.softness` (0...1, default 0, off is
  the previous bytes) multiplies the lens offset by a quintic window that is 0
  at the outline and the flat middle and replaces the hard offset ceiling by a
  smooth one, so refraction fades in from the rim without a start line, a kink
  or a smear; `GlassFill.richness` (0...1, default 0) adds a restrained surface
  window, warm sheet edges and a long soft reflection to a translucent liquid.
  Neither changes a record's size.
- Presence pass (PRESENCE, after the review "the restraint costs presence"):
  `GlassLighting.presence` (0...1, default 0, refined look only, experimental)
  makes the glass livelier through color and light, with no extra bend: the body
  picks up the backdrop's colors softly (a few wide samples, never a lens offset,
  scaled by a flatness gate so an edge, a dot or a character leaves no ghost), gains
  a hue-keeping luminance lift, and the inner edge carries a thin glow in the
  backdrop's hue, brighter on the lit side, with a deeper far side; a lens inlay gets
  a soft shade. It rides in `tint.w` as `1 + level` (the record keeps its 160
  bytes); non-finite is rejected with `nonFiniteLighting(.presence)`, finite is
  clamped; Reduce Transparency and Increase Contrast set it to 0. At 0 the shader
  draws the previous bytes. With it on, a plain rim refraction is feathered to 0 at the
  outline (never above its old value), which removes the step at a capsule's end caps.
  The lab applies it through `RefinedLook` (level 0.85, a lighter tint), the amber
  vessel's sheets are softer (two instead of three, no contour-line look), and the
  paper desk's captions no longer overlap.
- Clean pass (CLEAN, after the review "Apple's implementation is way cleaner than
  ours"): `GlassLighting.clean` (0...1, default 0, refined look, experimental) gives
  the rim one smooth gradient from the outline inward (no doubled line, no dark
  crease, no notch in the slab shade), soft wide chrome bands, a periodic thin-film
  hue and calmer glints, a smooth Increase Contrast polarity and no frost speckle;
  `GlassParameters.dither` (`GlassDither`, `.ordered` default, `.triangular`) adds a
  static isotropic triangular dither of one 8-bit step to every pixel, shadow and
  caustic, and smooths the glow and light palettes between their stops. `clean` rides
  in `tint.w` as `1 + presence + 256 * clean` and the dither mode in
  `GWGlassUniforms.padding0` (sizes and offsets unchanged); non-finite `clean` is
  rejected with `nonFiniteLighting(.clean)`, finite is clamped. Both at their
  defaults draw the previous bytes (the nine frozen-baseline suites pass). The lab
  uses both on every refined page and has a text-heavy bench page
  (`-lab.compare YES -lab.compareBackdrop text`). No bend, hairline or streak was added.
- The Metal 4 submission experiment (GW-11), package level and without public
  API: `Metal4Renderer` (`MTL4CommandQueue`, per-slot command allocators,
  argument tables, a residency set, commit feedback), `ConventionalPlanRenderer`
  (a control), `SubmissionBackend` and
  `RenderCapabilities.submissionBackend(preferringMetal4:)`. It runs only on a
  device that reports the Metal 4 family (My Mac here) and is compiled out for
  the iOS Simulator. No host uses it. The agreement test (four reference cases,
  0 of 12,648,528 bytes differ) and the interleaved comparison harness are in
  the characterization target; the recorded decision is in
  [the record](docs/decisions/metal-backend.md).
- Laboratory pages: Touch (`-lab.touch YES`), Merge (`-lab.merge YES`) and the
  SwiftUI example (`-lab.swiftui YES`), each with a menu button (see the
  README for the other arguments).

- `GlassLight` (`GlassParameters.light`): up to four emitters of colored
  light inside the glass (edge band, arc, orb, four corners), with piping,
  slow flow and drift, `.light` and `.paint` blends; the middle stays clear
  (GW-21). `GWGlassUniforms` grew append-only from 528 to 1776 bytes
  (GW-21 to GW-26), with size asserts in C, MSL and Swift.
- `GlassLens`: thick-lens profiles (rim, dome, ring), index of refraction,
  thickness, optional fold, chromatic dispersion with three or six taps, and
  up to two inlays, such as a dome button on a pill (GW-22).
- `GlassLighting`: one movable key light (`GlassRenderer.setLightOffset`),
  Fresnel, specular, studio reflections, chrome and prismatic finishes,
  bloom, a refined look and an enhanced look (`edgeDepth`, `banding`,
  `glints`) (GW-23, REFINE, ENHANCE-LOOK).
- `GlassFrost` (`GlassParameters.frost`): a blur pyramid with uniform,
  clear-center, clear-rim and vertical-ramp profiles, grain, saturation and
  a legibility scrim that guarantees a text contrast ratio (GW-24).
- `GlassGrounding`: drop, contact and inner shadows and a colored caustic
  (GW-25).
- `GlassShape` and `GlassBlob`: ellipses, superellipses and smooth blobs of
  up to six primitives with a loop-locked wobble; every effect follows the
  outline (GW-26).
- `GlassFill` and `GlassFillSlosh`: a luminous liquid or gel inside a glass
  vessel, curved and lit by the key light, with contour sheets, bubbles, a
  meniscus and a deterministic slosh; its own 784-byte record (GW-28).
- Presentation (GW-27): `GlassSurfaceView` takes its drawable on a
  background queue (a held drawable no longer stalls the main thread),
  `GlassMotionClass` with `beginInteraction()` and `endInteraction()`, and
  `GlassQuality` tiers with Low Power Mode and thermal downgrades through an
  injectable environment (default: no change).
- `NativeGlassView.Configuration.style` (`.regular`, `.clear`) maps to
  `UIGlassEffect.Style`.
- `GlassAccessibilityPolicy` rows for every new effect under Reduce
  Transparency, Increase Contrast and Reduce Motion.
- The laboratory: Apple vs GlassWeave, four material studies (Focus, Camera,
  Open Air, Amber), the material bench, light fields, thick lens, chrome and
  light, paper desk, shapes, liquid vessels, frosted glass, frost pyramid,
  native vs refined glass, and presentation pages, each with a launch
  argument (see the README).
- Look fixes (VESSEL, RING; found by the independent review of the capability
  round, checked in VERIFY-ROUND6): `GlassLighting.polish` (0...1, default 0)
  draws the refined look's chrome or prismatic edge as one polished torus (one
  bright and one dark flank, a thin bright line at each end, hue only on the
  brightest reflection and a few small glints) instead of mirrored pearly bands,
  packed in bits 8 to 15 of `GWLightingUniforms.environment`; Reduce
  Transparency and Increase Contrast remove it. `GlassFill.pooling` (0...1,
  default 0) gives the liquid a calm body whose light pools along the wall and
  the bottom with no hot core, packed in bits 16 to 23 of `GWFillUniforms.flags`.
  No layout changed and 0 draws the previous bytes. The lab's chrome ring
  (Pearl study, Chrome page, Tilt page) and its vessels (Touch page, Vessel
  study, Vessel bench, the Apple vs GlassWeave liquid row) use them; the round
  vessel on the Touch page is now a level fill that fills its circle. The
  ring is a neutral opaque metal, heavier than the native glass beside it, and
  the liquid is calm and flat, not luminous. Numbers and per-page verdicts:
  [studies](docs/studies.md#look-fixes-independent-check-verify-round6-experimental-unreleased).

### Changed

- The lab's Drag, Tilt and Touch pages draw GlassWeave's own button labels in the system label color
  under Reduce Transparency (white on the opaque light sheet was unreadable; the Touch page had it
  since GW-12). Nothing else on those pages changed (VERIFY-ROUND5).
- `GlassSurfaceView` runs its effect clock while any presented panel is
  animated (`GlassParameters.isAnimated`: glow, interior, light, wobble,
  fill), and `isEffectClockPaused` holds it for pinned captures.
- POLISH retuned the laboratory's glass (`RefinedLook.blend` and the studies):
  lower offsets, faint fringes, the soft window on every lens, a calmer touch
  (light 0.55, ripple 0.32, at most about 2.6 points of displacement), a larger
  chrome ring (98 points), a scrim that keeps its chroma as it darkens, and a
  merged pill that matches the buttons' brightness. These are opt-in values;
  a panel that sets none of them draws the previous bytes.
- Presence pass check (VERIFY-ROUND4): the first presence build left a faint
  lattice of ghost copies over a dot grid and a checkerboard and a pale second
  image of small colored dots under a thick lens; the pickup and the glow now
  follow the flatness gate (see `docs/glass-optics.md`, "Presence"). Bend geometry
  is unchanged or smaller; the same bend shows with about 19 percent more contrast
  on a black and white pattern because the old tint's haze is gone.
- GW-04 item 3 (the drawable stall) is closed by the GW-27 heartbeat test.
- Clean pass check (VERIFY-CLEAN): the pass and the commit before it were built
  fresh and captured on 28 pages with the same arguments. The doubled rim line, the
  ordered-dither cross-hatch and the thin chrome stripes are gone on every refined
  page, the glows and pooled lights are as smooth or smoother, and the displacement
  code was not touched (on a checkerboard the squares' edges inside the glass are
  pixel-identical). One lab retune: the frost page's capsule uses dispersion 0.3 and
  the soft window, because full dispersion turned two background stars at its rim into
  rainbow dashes. Per-page verdicts and what is still open (the four-corner light
  field's diagonal crease at its inner corners, a hard one-pixel band step on the
  chrome and pearl rings, a fine grain of about one 8-bit step, a rim wider and
  softer than the native line) are in `docs/studies.md`, "Clean pass".
- Clean pass 2 (CLEAN-2, after "I want to match Apple's, but at the same time have those
  glow capabilities that Apple cannot do"): with `GlassLighting.clean` on, the default rim
  is a thin crisp hairline (a Gaussian of the exact distance to the outline: about 0.5 pt
  wide at half maximum, 10 percent of its peak 1.3 pt in, one light and one shade around
  the outline), and the first pass's wide soft rim is the opt-in
  `GlassLighting.softRim` (0...1, default 0; non-finite rejected with `.softRim`, finite
  clamped; packed at 65536 times its 8-bit level in `lighting.tint.w`, sizes and offsets
  unchanged). Also under the clean look or the triangular dither: the four-corner light
  field's diagonal crease is smoothed (a 13-tap signed distance), a ring lens's profile
  turns up over its first four pixels at each end (the hard one-pixel step of the chrome
  and pearl rings is gone; the first four pixels of a ring are gentler, no bend is
  raised), the triangular dither goes only where the shader makes a gradient (a flat body
  has about a third of the grain), and the opaque panel under Reduce Transparency has its
  soft gray inner edge shade again. The independent check (VERIFY-CLEAN-2: both builds,
  38 pages, 3x, crops at 2x to 24x) found every page clean next to the native twin, the
  rim as thin as the native one on charcoal (half maximum 2.5 against 2.8 px, 10 percent
  at 4 px in both; before 8 px), every checkerboard edge inside the glass where it was
  (0.0 to 0.5 px), the glows smooth at 3x to 4x contrast and `-lab.softRim 1` equal to the
  first pass within 2 to 4 levels (`docs/studies.md`, "Clean pass 2").
- The `EnhancedNativeGlassViewTests` check "The pulse resumes where it stopped" measures how long the pulse ran instead of assuming 0.3 s, so a busy main actor no longer fails it.

### Known issues

- `GlowGalleryUITests.testAccessibilityAuditPassesInLightAndDark` failed in the
  dark audit (the Energy orb header) on this simulator in earlier rounds,
  identically on the shipped glow tip (the system appearance does not reach the
  app); it passed in the one run of the presence check, and nothing was changed
  for it, so it is not fixed. Two more
  timing-sensitive package tests (`EnhancedNativeGlassViewTests` "A new corner
  configuration..." and `FrameLifecycleTests` "100 hide and show cycles...",
  a race in the test itself) fail now and then. `GlassRenderer` now builds 16 pipeline
  variants at creation (about 6 to 15 ms, 1 to 4 ms before); see HANDOFF.md.
- Clean pass check (VERIFY-CLEAN) open items, fixed by clean pass 2 (the four-corner light
  field's crease, the rings' hard step, the opaque panel's edge shade; the grain is a third of
  what it was but still two times the native level).
- Clean pass 2 open items: the rim's lip on mid-tone backdrops is fainter than the native one
  (+20 against +50 levels on orbs), the native glass's near-black side lines are not matched,
  the dome button's outline has a one-pixel staircase at 12x, and no test covers the new terms.
  `PresentationUITests.testHeldDrawablesNeverStallTheMainThreadAndTheRequestDrawsOnRelease`
  timed out once in a full run while another job used the Mac and passed 3 of 3 alone.
- The touch response now reaches frost and fill panels (GW-34); the ring is
  invisible on frost by design, and the observer was never driven by a real
  finger. Merging was captured without frost, fill or touch on the merged panel.
- GW-30 to GW-34 (verified in VERIFY-ROUND5, simulator and My Mac only): the
  overlay cannot blur what it covers, so text under an overlay capsule stays
  crisp (dimmed, not frosted); the snapshot is static and a full-screen refresh
  exceeds its 33 ms bound on the simulator; the Core Motion source and every
  feel and cost question need a device; `PanelSpring`'s velocity carry-over has
  no trace test; a bright glyph under the rim of the snapshot capsule leaves a
  pale smudge with a faint inner arc at 5x.
- No physical device, no M5 cost run, no live VoiceOver pass; the acceptance
  items that need them or a test beyond the one safety test per task stay
  unchecked in `tasks/todo.md`.

## Unreleased: after the v0.1 candidate (experimental glow)

Requested by the user on 2026-11-09 and outside the v0.1 candidate's scope;
see [the glow design](docs/glow.md). Not released; simulator and Mac
evidence only.

### Added

- `GlassGlow`, a colored glow on a custom panel's edge: a rim band, an inner
  glow fading toward the middle, and an optional center fill, in one color or
  an angular gradient of up to four stops, lit from a chosen side; documented
  units, ranges, and normalization; `GlassParameters.glow`, default `.none`,
  which renders byte-identical output to the earlier shader (GW-17).
- `GlassAccessibilityPolicy` maps the glow: a thin crisp rim on the opaque
  body under Reduce Transparency, no inner glow or center fill under Increase
  Contrast; `GlassGlow.ColorStop(_:angle:traits:)` reads a stop from a
  `UIColor` (GW-17).
- The laboratory's `-lab.glow amber|aurora` launch argument (GW-17).
- A halo and a pulse for `GlassGlow` (GW-18): `haloRadius` and
  `haloIntensity` spill the glow colors outside the shape as light screened
  over the background, fading to exactly zero at the radius;
  `pulsePeriod` and `pulseDepth` modulate the rim, inner glow, and halo by
  `pulseLevel(at:)` at `GlassRenderer.effectTime` (`setEffectTime(_:)`).
  `GWGlassUniforms` grows to 256 bytes; glows without a halo render
  byte-identical output to the GW-17 shader.
- `GlassSurfaceView` runs an effect clock (`isAnimating`) only while a
  visible glow pulses, through its usual scheduler; `GlassAccessibilityPolicy`
  removes the halo and pulse under Reduce Transparency, keeps them under
  Increase Contrast, and holds the glow at the pulse's mean level under
  Reduce Motion (GW-18).
- The laboratory's `-lab.glow ember|energy` presets with a Pulse switch, and
  a glow mode in the Mac characterization (GW-18).
- `GlassInterior` (`GlassParameters.interior`, default `.none`): an animated
  energy, rays, or embers pattern inside a custom panel's outline, in a ramp
  of one to three colors, with intensity, speed, a seed, and a center fade
  that keeps the middle exactly see-through; deterministic for a seed and
  time, repeating every 64 s of interior time, screened over the glass as
  light; embers' sparks may rise into the glow's halo. `GWGlassUniforms`
  grows to 528 bytes; panels without an interior render byte-identical
  output to the GW-18 shader (GW-19).
- `GlassSurfaceView` runs its effect clock while a visible interior moves;
  `GlassAccessibilityPolicy` removes interiors under Reduce Transparency and
  Increase Contrast and shows the still frame under Reduce Motion;
  `GlassInterior.Color(_:traits:)` reads a `UIColor` (GW-19).
- The laboratory's `-lab.interior energy|rays|embers` with an Interior
  motion switch, and interior modes in the Mac characterization (GW-19).
- `EnhancedNativeGlassView` (GW-14, pulled forward with the glow work): a
  `GlassGlow`'s rim and halo, and its pulse, drawn with Core Animation around
  a genuine `NativeGlassView`, whose material stays Apple's; the laboratory's
  `-lab.nativeGlow <preset>` with a Native glow switch. (Added to this list
  with GW-20; it was missing.)
- Several panels in one pass (GW-20): `GlassRenderer.setPanels(_:)`,
  `panels`, and `maximumPanelCount` (8) draw an ordered list of panels over
  one frame, each as its own quad (where quads overlap, the later panel
  wins); `setPanel(_:)` is the one-panel case and renders the same bytes.
  `GlassSurfaceView.setPanels(_:)`, `panels`, and `presentedPanels` apply the
  accessibility policy to each panel and run the effect clock while any
  presented panel animates.
- The laboratory's glow gallery (GW-20), from its Glow gallery button or
  `-lab.gallery YES`: a light/dark switch with a glass knob, three element
  capsules with their own edge colors and interiors (and a check under the
  selected one, which shows the selection without the glow), an energy orb, and
  native glass with a colored rim, drawn by one surface in one pass under
  native controls, submitting no frames at rest.

## Unreleased: v0.1 pre-alpha candidate

Not released and not tagged. Every API is experimental. No physical device
has been measured; see [the pre-alpha notes](docs/evidence/pre-alpha.md).

### Added

- Swift package (tools 6.2, Swift 6 language mode) with the `GlassWeave` core
  and `GlassWeaveUIKit` products. Declared floors: iOS/iPadOS 26 and macOS 26,
  neither of which has been run; tests ran on the iOS 27.2 simulator and on
  macOS 27.2, where the core is compiled and GPU-tested (GW-01).
- `RenderCapabilities`, a runtime survey of the rendering `MTLDevice`'s GPU
  families, kept separate from the OS deployment floor (GW-01).
- The UIKit laboratory app, `GlassWeaveLab`, consuming the package through a
  local reference, in a combined workspace (GW-02).
- Native mode: `NativeGlassView`, a `UIVisualEffectView` with a public
  `UIGlassEffect` (tint, interaction), creating no GlassWeave renderer (GW-03).
- The explicit background-source contract: `BackgroundFrame`,
  `BackgroundFrameLease`, `BackgroundFrameRelease`, `SourceUVTransform`
  mapping, `BackgroundSourceError`, defined skips, and `BackgroundRenderer`;
  `GlassSurfaceView`, an `MTKView` host sized from its own bounds and display
  scale; a shared C layout target for GPU records (GW-04).
- One rounded refractive panel: `GlassRenderer`, `GlassPanel`,
  `GlassParameters`, `GlassTint`, with documented units, ranges, and
  normalization (GW-05).
- Frames produced inside the draw's own command buffer
  (`GlassRenderer.drawProducing`, `GlassSurfaceView.setFrameProducer`), so
  the background and the refraction show the same frame (GW-06).
- On-demand, per-scene, bounded rendering: at most two frames in flight,
  coalesced requests, visibility per host and window scene,
  `FrameStatistics`, and `FrameTexturePool` (GW-07).
- Accessibility: a decorative surface hidden from assistive technologies,
  `GlassAccessibilityPolicy` (opaque surface under Reduce Transparency; Reduce
  Motion reported to the app), and the tinted-glass legibility rule
  (`GlassTint.worstCaseContrast`, `minimumStrength`) (GW-08).
- `RenderMetrics`, opt-in per-renderer measurement of CPU encode, producer,
  and drawable-acquisition time, GPU start/end per command buffer, counts, and
  allocated bytes; the laboratory's benchmark scenario
  (`-lab.benchmark baseline|native|custom|idle|lifecycle`); and an offscreen
  characterization test with a Release scheme (GW-09).
- A DocC catalog whose examples are compiled and run by the tests, a support
  matrix, and these notes (GW-10).

### Known limitations

- No physical iPhone or iPad has been measured; no device is qualified and
  every performance budget is unmeasured on hardware.
- Results so far come from the iOS 27.2 Simulator and an Apple M5 Mac on
  macOS 27.2; no iOS 26 runtime was available and macOS 26 was not run.
- iPad presentation is not claimed: only the iPad Pro 13-inch (M5) simulator
  ran, in full-screen apps mode, and no physical iPad.
- `GlassSurfaceView` acquires drawables on the main thread, which can wait
  for a free drawable (normally at most about one display refresh, up to one
  second when none is free).
- One source format (`bgra8Unorm_srgb`, opaque); no wide color, HDR,
  transparency, or video.
- Same-queue ordering only; no cross-queue or external producer.
- No macOS view; no SwiftUI adapter (in the v0.1 candidate; the experimental adapter is a later addition, above).
- The CI workflow has not run on GitHub.

### Not included in v0.1

Touch ripple, custom/custom merging, enhanced-native effects, a SwiftUI
adapter, external producer or texture interoperability, and a Metal 4 backend.
(Later, experimental and unreleased: enhanced-native effects, the touch
ripple, custom/custom merging and the SwiftUI adapter exist on the glow and
glass-beyond branches, described above.)
