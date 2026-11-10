# Material studies (GW-29)

Four lab screens that put GlassWeave's own glass next to Apple's and show what it adds. Each is built only from public GlassWeave API and a procedural background written for it (`Examples/GlassWeaveLab/GlassWeaveLab/Studies/StudyBackgrounds.metal`); no reference picture, crop or traced asset is used or stored. The direction is Apple's Liquid Glass with more capability: a mostly clear body, a thin crisp rim, one light from the upper left, quiet color, calm shadows, generous negative space. Every study can add a real `UIGlassEffect` capsule on the same backdrop (`-lab.studyTwin YES`) so the two can be compared by eye.

> The API these studies use is experimental. The studies themselves change nothing in the package; the two package edits of this pass (the native `.clear` style and the gel's noise level) are described below.

## How to open them

| Launch argument | Effect |
| --- | --- |
| `-lab.study pearl\|pill\|shelf\|vessel` | Opens the study as the window's root. The lab's "Material studies" menu opens the same screens over the window. |
| `-lab.studyTime <seconds>` | Pins the script at that time: a capture is repeatable, and two runs show the same picture. |
| `-lab.studyTwin YES` | Adds a native `UIGlassEffect` capsule at the bottom for comparison. |
| `-lab.studyDiagnostics YES` | Shows the diagnostics line (panels, rule 10, draws, backgrounds, accessibility settings). |
| `-lab.reduceTransparency YES`, `-lab.reduceMotion YES`, `-lab.increaseContrast YES` | The existing accessibility stand-ins. |

## What they share

- **One surface and one producer.** The producer draws the background and returns `nil` while nothing about it has changed. The pearl and the pill have still backgrounds: one background frame, then none.
- **A script, not a clock.** The surface's effect clock is paused. Every moving thing is a pure function of the script time, ticked 30 times a second, and every animated parameter is quantized so the panel changes at most a few times a second (the pill draws about 4 times a second while it runs). Under Reduce Motion the script rests at its first moment and no tick runs.
- **Rule 10.** The screen estimates each panel's quad (outline, halo, the grounding's reach) from the public values and reports whether any two overlap. The package's own report is not public; the estimate follows its formula. The pearl keeps its two panels 50 points apart for that reason, so its shadows are compact and the plate carries the larger soft shadow.
- **Native controls.** Buttons, labels and titles are UIKit; each has a VoiceOver label; layout uses leading and trailing, so it mirrors (see the right-to-left capture, where the dome moves to the leading end).
- **Accessibility policy.** Reduce Transparency turns each panel into the opaque surface with a crisp rim; Increase Contrast raises the scrims to 7:1 and removes the dispersion; nothing is implemented in the lab for this, it is the package's policy.

## Pearl (light; target: a small chrome-ring button on an embossed plate)

A round button with a polished, prismatic chrome ring sits in a round well pressed into a plate, beside a milky capsule with a native label and a soft text shadow.

- The plate and the well are drawn by the producer (`study_pearl_fragment`): a raised rounded rectangle with a bevel, a long soft shadow away from the light and a tight contact line, and a dish whose far wall lies in shadow. They are not panels.
- Panel 1, the ring button: a `ring` lens (thin band at the edge, clear middle), the refined light with a prismatic finish reflecting a dark studio so the band reads as polished steel with thin-film hints, and a compact drop and contact shadow.
- Panel 2, the milky capsule: a light frost, a white tint, the refined rim and the same compact shadow.
- Script: the key light swings 8 degrees to either side over 14 seconds, so the glints travel around the ring.
- Met: embossed plate and well, a polished ring with prismatic glints, a milky pill, soft drop and contact shadows. POLISH: the ring is larger (98 points, a band 0.17 of the diameter wide), with deeper stripes and five groups of small glints; its lens bends little (a 9-point ceiling, faint fringes). Approximated: the ring is steel-silver with faint color; the reference's band is a stronger chrome contrast. The center is clear, not a dome.

## Pill (target: a wide thick lens pill with a pooled bottom glow and a dome button)

A focus-session pill over a soft field of large fuzzy spheres (`study_pill_fragment`: nine spheres, Lambert-shaded from the upper left, felted surface and edge).

- One capsule panel: a squircle bevel that magnifies what lies behind its edge, six-tap dispersion at the bevel only, a light frost (about 2.6 points) with grain, the refined top highlight, and a four-stop pooled glow along the bottom (a `GlassLight` band: sky, violet, rose, amber) that flows one palette turn per 64 seconds.
- The dome is an inlay of the same panel (GW-22), at the trailing end, mirrored in right-to-left. A native pause button sits on it and stops the script (and the glow); the native time label carries a 3:1 scrim (large text).
- Script: the time counts up in seconds from 12:04.
- POLISH: the bend is subtle and blended (the soft window of `GlassLens.softness`, a 7-point ceiling, faint fringes), and the frost is clear at the rim so the bevel is not smeared.
- Met: a gentle lens bend at the bevel (smooth where a sphere crosses the pill), light frost, top streak, four-stop pool, inlaid dome. Approximated: the pool is thinner and calmer than the reference's; the dome has little behind it to magnify.

## Shelf (target: a frosted capsule bending what is behind it, with rainbow fringes)

A frosted capsule holds a large native title and three native buttons, over a blue sky with a soft rainbow arc and seven pearly pebbles that drift a few points over 48 seconds (`study_shelf_fragment`).

- One capsule panel: an even frost (6 points), a thick bevel with six-tap dispersion (0.42), a thin rim, and a legibility scrim on the title and the controls (3.5:1, 7:1 under Increase Contrast).
- The pebbles and the arc pass behind the bevel, so the frost's blur and the dispersion show.
- Cost: the frost pyramid is rebuilt each frame while the pebbles drift (30 times a second); under Reduce Motion nothing ticks.
- POLISH: the scrim keeps the color rich as it darkens (chroma lift at constant luminance) and fades over 22 points, so no gray-teal smudge sits under the title where a pale pebble is; the bend is the same soft, blended one.
- Met: frost, a gentle bevel bend with faint fringes, a guaranteed-contrast title. Approximated: the rainbow arc is soft, not a prism.

## Vessel (target: thick, smoky glass holding a calm luminous liquid, on a dark stage)

An original composition around the GW-28 liquid fill: two vessels, each one panel, on a near-black stage (`study_vessel_fragment`: a cool wall that warms toward the table, one very faint far soft box at the upper left, the warm light each vessel throws on the table, a soft vignette).

- The large vessel is a rounded rectangle with a refined thick lens (squircle bevel, dispersion 0.10, the thin lit-side rim) and a smoky tint, so the glass is nearly clear and dark. It holds a **gel**: a smooth rounded body low in the glass, one warm ramp (deep amber, orange, pale gold), two soft sheets (PRESENCE: 24 points apart, edge 0.34, wobble 0.85, so they read as folds in one gel and not as contour lines), a thin line in the glass wall, six tiny bubbles.
- The small vessel is a tall rounded rectangle holding a **level** liquid (surface waves 0.5 pt, meniscus 3 pt). A native "Liquid level" slider fills it and a native "Nudge" button starts a damped slosh (`GlassFillSlosh`) that the 30 Hz script tick steps until it settles; Nudge is disabled under Reduce Motion. The level also lights the table under the small vessel a little more.
- The surface's effect clock moves the bubbles and the gel's slow wobble (the other studies pause it; a pinned `-lab.studyTime` pauses it here too, so a capture is repeatable). The stage is a still picture, drawn again only when the layout or the level changes.
- POLISH (`GlassFill.richness` 1 and 0.8): a restrained specular window on the liquid's own curved surface, brighter warm sheet edges, fine internal structure in the gel, and a long soft reflection along the lit outer wall.
- Met: calm luminous liquid with a bright thin edge, smoky thick glass with a crisp rim, sparse tiny bubbles (no rings or crescents), generous negative space, native controls. Approximated: reference 1 has a far richer dark glass (a thick curved refraction of the liquid through the rim); ours is a lit rim, one soft outer reflection and a dark body. A level liquid in a rectangle shows soft diagonal creases where the liquid's depth profile folds at the corners (the dome profile has no smoothing there), so the large vessel uses a gel, whose rounded body has none.
- One shader change for this study, in the filled pipeline only: the gel's heat noise went from a 50% to a 24% modulation and its fine noise from 14% to 8%, because the first capture looked mottled and dirty. `.none` is untouched (the GW-28 baseline test is unchanged).

## Captures

`docs/evidence/captures/gw-29-study-*.png`, iPhone 18 Pro simulator. The "vs native" captures (pearl, pill, shelf, vessel) are full size and include the real `UIGlassEffect` capsule at the bottom; the "half" captures are half size (reduce transparency, right-to-left, increase contrast).

## The Apple vs GlassWeave screen: the refined rows

`VersusViewController` (`-lab.versus YES`) now has ten rows. The first four (hues, clear middle with colored rim, light from one side, animated interior) are the GW-29a glow rows, with a softer halo. Six refined rows follow, one per feature; each native half is the genuine `UIGlassEffect` alone (no GlassWeave rim or halo), the weave half is built for a light and a dark page, and each caption states only what the code or Apple's public API does:

| Row | Native half | GlassWeave half |
| --- | --- | --- |
| A thick lens with dispersion | `NativeGlassView` style `.clear` (new) | squircle bevel, six-tap dispersion 0.7, nearly clear body |
| Inner light and pooled color | one blue tint | three colors pooled along the bottom edge, clear middle |
| Chrome and prismatic finishes | regular glass | thin ring band, light studio, prismatic finish (softer in dark) |
| Frost with a clear center | regular glass | `clearCenter` frost, sigma 12 |
| Freeform shapes | capsule (`cornerConfiguration`) | a three-part smooth blob with a slow wobble |
| Liquid fill | one orange tint | a gel in a smoky vessel, one sheet, three bubbles |

The "Animate interiors" switch also holds the light's flow, a blob's wobble, and the fill's bubbles and waves. The hierarchy check (native half: `UIGlassEffect` views, no GlassWeave surface; weave half: one surface) and the divider clipping are unchanged.

`NativeGlassView.Configuration.style` (`.regular` default, `.clear`) maps to `UIGlassEffect.Style`. Its doc comment carries Apple's advice for clear glass: over bright content add a dark dimming layer of about 35% opacity behind it; none is drawn by the view.

## Presence pass (PRESENCE and its check, experimental, unreleased)

The refined panels of the studies and of the lab pages now carry `GlassLighting.presence` (0.85 through `RefinedLook`): the body picks up the colors behind it, lifts a little without graying, and the inner edge glows softly in the backdrop's hue on the lit side, with a deeper far side. Nothing is bent further: the plain rim refraction is only feathered toward the outline, and every lens, offset, dispersion and touch value is as before. Beside the real `UIGlassEffect` twin the gap is narrowed, not closed: our body is still clearer (the native one is frosted and carries a stronger hairline), and on the paper page a refined panel reads as a soft cushion more than as glass. The independent check (VERIFY-ROUND4) recaptured every page from a fresh build beside the previous build and found one defect, a ghost lattice and a pale double image of small dots over high-frequency backdrops, which a flatness gate removed (`docs/glass-optics.md`, "Presence"; captures `gw-presence-verify-*`). The amber study is one clean gel; the paper desk's captions no longer overlap. Simulator only; nobody has looked at it on a device.

## Clean pass and its independent check (CLEAN, VERIFY-CLEAN; experimental, unreleased)

> **Superseded in part by [clean pass 2](#clean-pass-2-and-its-independent-check-clean-2-verify-clean-2-experimental-unreleased).** The rim is now a thin crisp line, the light field's crease, the rings' hard step and most of the body's grain are fixed; the table and the open list below describe the first pass.

The studies and every refined lab page now ask for the clean rim and the triangular dither (`GlassLighting.clean`, `GlassParameters.dither`, both opt-in; notes in [glass-optics](glass-optics.md#clean-pass-match-the-system-glasss-cleanliness-clean)). The user's feedback was that the native glass is much cleaner than ours, with bands and streaks. The rim now falls off in one gradient from the outline: the doubled inner line (a second ridge a few points inside the hairline), the ordered-dither cross-hatch and the thin chrome stripes are gone, and the glow and pooled-light gradients are as smooth as before or smoother.

The independent check (a fresh build of the pass and a fresh build of the commit before it, the same launch arguments, 3x captures, crops at 2x to 16x, some with the contrast stretched) found the pages below. "Clean" means no streak, stripe, band, step, doubled line, dash or banding that the native twin does not also show at that zoom.

| Page | Verdict | Where it is not like the native twin |
| --- | --- | --- |
| Apple vs GlassWeave, charcoal, orbs, paper, text | clean | the rim is a gradient about ten points wide where the native one is a thin line; a fine static grain of about one 8-bit step (neighbour difference rms 0.8 to 1.2 levels on a flat body, native 0.1 to 0.2; the native body shows 8-bit contour steps when the contrast is stretched five times, ours shows none), invisible below about 4x; on paper the panel reads as a soft cushion with a wide shadow |
| Studies: pill, shelf | clean | the pill's pooled glow and the shelf's frost are smooth at 4x contrast |
| Study: pearl | mostly clean | the thin-film arc is a deliberate narrow rainbow band; a hard one-pixel step (about 70 levels, no antialiasing) between the ring's dark outer band and its bright lip, a 1 px staircase at 8x to 16x, not visible at 1x to 3x |
| Study: vessel | mostly clean | faint wavy sheet lines in the liquid, by design (wider and fainter than before) |
| Lens, shapes, merge, touch | clean | the lens "fold on" demo notch and the checkerboard bend are the lens itself |
| Chrome | mostly clean | the same ring step as the pearl; the softer bands and one arc |
| Paper desk | mostly clean | the lens pill turns small dots into eggs and the marble bends its grid (the lens, unchanged) |
| Frost | clean after the check's retune | two background stars at the rim were squeezed and fringed into rainbow dashes by the frosted capsule's full dispersion; the lab's capsule now uses dispersion 0.3 and the soft window |
| Light fields | mostly clean | the four-corner field shows a diagonal crease at each inner corner (see below) |
| Glow gallery, Apple vs GlassWeave rows | clean | the glow halos and the amber to magenta fill are smooth at 3x to 4x contrast, with no banding |

**Still open from the check.** (1) The four-corner light field's pooled light is a function of the distance to the outline, which has a crease along the diagonals at a rectangle's corners; it shows at normal size on the Light fields page (capture `gw-verify-clean-light-field-corner-crease-*`) and is the same as before the pass. A fix needs a smoothed distance in `gw_light_emitter` behind `clean` or the dither; it was not made. (2) The ring's hard step. (3) The grain and the wider rim above, by design of the dither and of the PRESENCE look. (4) Under Reduce Transparency the opaque panel lost its soft gray inner edge shade and is now a flat panel with a crisp edge (on paper the hairline stays); Increase Contrast's dashes at the cyan orb's edge are gone (`gw-verify-clean-increase-contrast-top-edge-*`). Bends: the displacement code was not edited, and on a checkerboard the squares' edges inside the glass are pixel-identical before and after (no pixel differs by more than 100 levels in any panel; the only differences that large are in the page's native segmented control row); the bend itself is still visible as a bend on a checkerboard at the bevel, which is the lens, not this pass.

## Clean pass 2 and its independent check (CLEAN-2, VERIFY-CLEAN-2; experimental, unreleased)

The second clean pass made the default rim a thin crisp hairline (the wide soft rim is the opt-in `GlassLighting.softRim`, the lab's `-lab.softRim 1`) and fixed the light field's crease, the rings' hard step, the body's grain and the opaque panel's edge shade (notes: [glass-optics](glass-optics.md#clean-pass-second-round-a-thin-crisp-rim-five-fixes-clean-2)). The independent check built the pass and its parent (`887103b`, from `git archive`, so nothing in the checkout was touched) fresh, captured 38 pages with the same launch arguments on the iPhone 18 Pro simulator at 3x, and cropped at 2x to 24x, some with the contrast stretched 3x to 24x, beside the real `UIGlassEffect` twin. Verdicts use the same rule as above: "clean" means no streak, stripe, band, step, doubled line, dash, crease, grain or banding that the native twin does not also show at that zoom. Captures: `gw-verify-clean2-*` (own renders only).

| Page | Verdict | What is left, and where ours is not like the native twin |
| --- | --- | --- |
| Apple vs GlassWeave, charcoal | clean, as clean as the native twin | the thin line matches the native rim (below); the body is smoother than the native body at 24x contrast (the native one shows 8-bit contour terraces, ours a faint dither only where it has a gradient); neighbour difference rms 0.34 against 0.17 on a flat body; ours is darker (body 48 against 62) and has no near-black dark line at the left and right sides |
| orbs | clean | the lip is less than half as bright as the native one (+20 to +24 against +47 to +51 levels at the top) and falls off over 4 to 6 px where the native one takes 3 to 4; nothing doubled or streaked |
| paper | clean | one dark line, 1 px, 26 levels under the page at the top (native 2 px, 25 levels), 26 against 82 levels at the sides; no white lip (native +7); rms 0.49 against 0.25 |
| text | clean | no ghost copy, type crisp inside the panels; its rms is the type itself |
| Studies: pill, shelf | clean | the pooled glow (pill) and the frost body (shelf) are smooth at 4x; the shelf's edge is a faint gray line on the blue; the dome button's outline shows a one-pixel staircase at 12x (the same before) |
| Study: pearl | clean (the ring step is fixed) | the hard staircase on the ring's outer band is gone at 2x to 8x; the thin-film arc is the deliberate narrow rainbow band |
| Study: vessel | clean | the wavy sheet lines in the liquid, by design, at 4x |
| Lens, shapes, merge, touch | clean | the lens demos bend as before (checker edges inside the glass moved by 0.0 to 0.4 px between the builds); the touch swell is as before |
| Chrome | clean (the ring step is fixed) | the ring's outer band is smooth at 8x |
| Paper desk | clean | the lens pill still turns small dots into eggs (the lens, unchanged) |
| Frost | clean | two background stars at the rim are still squeezed into small fringed slivers, a few pixels long, the same as before |
| Light fields | clean (the crease is gone) | smooth at the four inner corners of the four-corner field on charcoal, ribbons and paper at 3x contrast |
| Glow gallery (dark and light), versus | clean | halos, orb, toggle and the amber to magenta fill are smooth at 3x to 4x; a one-pixel horizontal line across the halo below each capsule at 4x contrast (the same before) |

**The rim, measured.** Luminance profiles across the top, bottom and side edges of the capsule, the rounded rectangle and the circle, the mean of twelve columns, at 3x (the same definitions for both; the first pixel is partly covered, so these widths run about one pixel more than the sub-pixel widths in the glass-optics table). Charcoal top edge: native peak +50 over the body, half maximum 2.8 px, 10 percent of the peak at 4 px; ours before +57, 2.7 px, 8 px; ours after +53, 2.5 px, 4 px. Rounded rectangle: native +51, 2.7 px, 4 px; ours after +55, 2.6 px, 4 px. Circle: native +38, 3.2 px, 5 px; ours after +46, 2.8 px, 4 px. On charcoal the edge now matches the native one in width and falloff. At the bottom edge ours is +26 against the native +50 (one light from the upper left, by design), and at the sides the native glass has a near-black line (5 against a page of 28) where ours has none. The soft-rim opt-in (`-lab.softRim 1`) draws the first pass: no pixel of the compare pages differs from the parent by more than 2 levels on charcoal, 3 on orbs and 4 on paper (`gw-verify-clean2-soft-rim-opt-in-*`).

**Bends.** No bend became more visible. Along eleven rows through the lens page's checkerboard panels and eleven through the compare page's refined panels (the crossings of the 128-level line, with sub-pixel interpolation), every dark/light edge inside the glass sits where it did in the parent: 0.0 to 0.5 px, almost all under 0.1 px, the largest next to the rim line whose brightness changed. In the pill's bottom 40 px the pooled light's level changed, so some crossings appear or vanish and the ones that remain sit within 0.03 px. A difference image of the lens page is bright only in the bevel (`gw-verify-clean2-bend-diff-lens-checker-x4-*`). The bend is still visible as a bend on a checkerboard at the bevel: with the wide soft rim gone nothing masks it any more (`gw-verify-clean2-checker-cap-*`).

**Still open.** The lip on mid-tone backdrops (orbs) is fainter than the native one; the native side lines (near black on charcoal, 82 levels on paper) are not matched; our body is darker than the native body on charcoal; the grain on a flat body is two times the native level (0.34 and 0.49 against 0.17 and 0.25); the dome button's outline has a one-pixel staircase at 12x. Simulator only; nobody has looked at it on a device.

## Vessel calm pass (VESSEL, 2026-11-10; experimental, unreleased)

The independent review found the round vessel on the Touch page "an orange lamp in a gray ring". Two causes, both found by looking at zoomed crops: the round vessel held a small **gel** (a circle at 0.62 of its radius), so a wide annulus of tinted glass lay between the liquid and the outline, and the fill's wall line, tight and wide warm spill, long reflection and far-side rim drew concentric gray bands in it (the "ring"); and the body's brightness peaked in the thick middle, which a small disc turns into a hot yellow core (the "lamp": peak G 170 and B 74, with R clipped at 255). The shadow, the halo and the touch ring were not involved (the vessel look has no halo, no shadow on a dark page, and no touch at rest).

What changed:
- **`GlassFill.pooling`** (0...1, default 0, normalized, `nonFiniteFill(.pooling)`; opaque ignores it), packed in bits 16...23 of `GWFillUniforms.flags` (no layout change). Above 0 the body's light pools along the glass wall and, in a level, the bottom (brightest and most saturated there) and falls off smoothly toward the surface and the middle, with a soft depth saturation (no ridge), a ramp that stops short of its palest end, the slow masses reduced to a faint drift, and the backdrop absorbed evenly (a dye, so a busy page does not show through the middle). A calm body is also not lifted by the refined look's backdrop pickup (the presence) and not by a touch (neither the finger light nor the ring's catch light), so the finger lifts the glass only. Every added term is behind `pooling > 0`; 0 draws the bytes it drew before.
- **The lab's vessel family** (`VesselLook.swift`): clear glass (tint strength 0.14, dispersion 0.08, a soft contact shadow), one warm ramp (0.36 0.05 0.01, 0.95 0.34 0.04, 1.0 0.60 0.18), `emission` 1, `absorption` 0.85, `gloss` 0.3, no contour sheets, 2 to 3 bubbles of 1.5 pt, a level surface with a 0.25 pt swell over 150 pt and a 2.4 pt meniscus. The round vessel became a **level** fill filling its circle (so there is no annulus); the pill, the Vessel study, the Vessel bench and the Apple vs GlassWeave liquid row use the same recipe (the study's slosh keeps its nudge, with waves 0.25 + 1.8 x agitation).
- Peak body brightness, rest state (interior of the liquid, away from the edge lines): round vessel max (255, 170, 74) before and (222, 95, 20) after; pill (255, 191, 113) and (236, 158, 105, a bubble); study gel (255, 193, 150) and (255, 162, 74); the 99th percentile luma fell from 173 to 115 (round), 176 to 112 (pill), 191 to 150 (study). Nothing in the body is yellow-white any more; the brightest pixels now sit on the thin lit-edge line, golden orange.
- Limits: the opaque (Reduce Transparency) fill is unchanged, so it shows the new ramp's orange as one flat color; the calm gel is plainer than the earlier richness look by design (no sheets, no window highlight); a level in a circle shows a visible meniscus climb at the wall that is not drawn in a gel.

## Polished chrome ring (RING, 2026-11-10; experimental, unreleased)

The independent review read the chrome ring as a soap bubble: two or three concentric pearly bands with rainbow tints, a white gap and a gray band. Cause: the polished bands are a function of the surface tilt, which is even about the crest of a ring (the normal tilts outward on the outer slope and inward on the inner one), so they come in mirrored pairs; the thin film then colors each band all the way around; and the opacity of the metal fell to nothing at the crest, where the surface is flat.

**What changed.** A new opt-in field `GlassLighting.polish` (0...1, default 0, packed in bits 8 to 15 of `GWLightingUniforms.environment`, which is 32 bits wide and read only in its low byte: no layout change). With it the polished edge is drawn as a polished torus: the metal's brightness is a smooth function of the direction the surface reflects (a floor, a wall that is bright toward the key light and dark beyond the far side, a broad sky overhead, a soft box high on the light's side), so the profile is continuous across the crest with one bright and one dark flank, a thin bright line at each end, no stripes and no pairs. The side of the ring toward the light is brighter as a whole (7 percent and 2.5 percent of display level by the outline's direction, 11 and 4 on the shipped ring). The thin-film hue is confined to the brightest reflection and to four small glints (windows of the normal's azimuth and tilt, about 4 degrees by 5), which turn with the light. Off by default; every other panel and every opt-out path draws the same bytes (the eleven frozen-baseline suites pass unmodified). Reduce Transparency and Increase Contrast remove it with the finish (`presented.polish = 0`); the ring falls back to the thin crisp rim.

**Lab values** (`RefinedLook.chromeRing`): the ring starts at the outline and is 0.19 of the diameter wide (0.17 before, with a flat gap at the outline that read as a second line); thickness 0.18 of the diameter (the same height as before); `polish` 1; prismatic spread 0.5, saturation 0.5, phase 0.62; glints 1; band width 1.4 times the ring width, so the metal is not faded toward its inner end; the lens keeps offset 9, dispersion 0.12, softness 1.

**Numbers** (iPhone 18 Pro simulator, 3x, luminance extrema of at least 6 levels along 12 radial profiles). Pearl ring: 2.83 maxima and 3.67 minima before, 1.42 and 2.17 after. Tilt ring on paper: 2.50 and 3.75 before, 1.00 and 2.08 after; on the orbs 2.00 and 1.67 before, 1.25 and 1.33 after. Hue of the ring pixels (mean chroma; share of pixels with chroma above 0.04; chroma-weighted circular spread): pearl 0.052, 33 percent, 71 degrees before; 0.006, 3 percent, 53 degrees after. Tilt ring on the orbs 0.105, 79 percent, 63 degrees before; 0.023, 16 percent, 48 degrees after. Lit arc against far arc (a 70 degree arc around the light and around its opposite, the ring body, mean luminance), roll -30 and +30: paper 174 against 143 (+31) and 174 against 143 (+31); orbs 160 against 129 (+31) and 160 against 126 (+34); stage 157 against 120 (+37) at both; before the difference was 1 to 2 levels on paper and negative on the orbs. At 8x to 10x with nearest-neighbor sampling the outline, the inner end and the highlight edges show no staircase (`gw-ring-zoom-8x-edges-*`).

**Limits.** The inner end of the ring is a soft four pixel ramp (the earlier CLEAN-2 fix for its step), not a crisp line; the pale lip at the inner end can read as a thin second line on a dark page; the glints are faint at the Tilt page's 86 point ring; the tilt only turns the light by a few degrees, so the reaction is a shift of the dark band and the glints, not a new picture; under Increase Contrast the ring's refraction of a grainy backdrop (the orbs) still shows faint radial streaks (the quiet bend of the ring's lens, unchanged); the metal is neutral and does not reflect the colors of the backdrop. Tuned by eye, simulator only, nobody has looked at it on a device.

## Not done in this pass

Dynamic Type at the largest sizes, the accessibility audit, iPad and landscape captures (the studies were smoke-run once on the iPad simulator, no capture kept), the right-to-left and largest-text versus captures, a captured nudge frame of the vessel study, and full-frame M5 characterization.
