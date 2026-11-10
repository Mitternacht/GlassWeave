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

## Not done in this pass

Dynamic Type at the largest sizes, the accessibility audit, iPad and landscape captures (the studies were smoke-run once on the iPad simulator, no capture kept), the right-to-left and largest-text versus captures, a captured nudge frame of the vessel study, and full-frame M5 characterization.
