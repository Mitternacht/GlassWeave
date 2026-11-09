# Material studies (GW-29)

Three lab screens that put GlassWeave's own glass next to Apple's and show what it adds. Each is built only from public GlassWeave API and a procedural background written for it (`Examples/GlassWeaveLab/GlassWeaveLab/Studies/StudyBackgrounds.metal`); no reference picture, crop or traced asset is used or stored. The direction is Apple's Liquid Glass with more capability: a mostly clear body, a thin crisp rim, one light from the upper left, quiet color, calm shadows, generous negative space. Every study can add a real `UIGlassEffect` capsule on the same backdrop (`-lab.studyTwin YES`) so the two can be compared by eye.

> The API these studies use is experimental. Nothing here changes the package.

## How to open them

| Launch argument | Effect |
| --- | --- |
| `-lab.study pearl\|pill\|shelf` | Opens the study as the window's root. The lab's "Material studies" menu opens the same screens over the window. |
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
- Met: embossed plate and well, a polished ring with prismatic glints, a milky pill, soft drop and contact shadows. Approximated: the ring is steel-silver with faint color; the reference's band is a stronger chrome contrast. The center is clear, not a dome.

## Pill (target: a wide thick lens pill with a pooled bottom glow and a dome button)

A focus-session pill over a soft field of large fuzzy spheres (`study_pill_fragment`: nine spheres, Lambert-shaded from the upper left, felted surface and edge).

- One capsule panel: a squircle bevel that magnifies what lies behind its edge, six-tap dispersion at the bevel only, a light frost (about 2.6 points) with grain, the refined top highlight, and a four-stop pooled glow along the bottom (a `GlassLight` band: sky, violet, rose, amber) that flows one palette turn per 64 seconds.
- The dome is an inlay of the same panel (GW-22), at the trailing end, mirrored in right-to-left. A native pause button sits on it and stops the script (and the glow); the native time label carries a 3:1 scrim (large text).
- Script: the time counts up in seconds from 12:04.
- Met: lens magnification at the bevel (visible where a sphere gap crosses the pill), light frost, top streak, four-stop pool, inlaid dome. Approximated: the pool is thinner and calmer than the reference's; the dome has little behind it to magnify.

## Shelf (target: a frosted capsule bending what is behind it, with rainbow fringes)

A frosted capsule holds a large native title and three native buttons, over a blue sky with a soft rainbow arc and seven pearly pebbles that drift a few points over 48 seconds (`study_shelf_fragment`).

- One capsule panel: an even frost (6 points), a thick bevel with six-tap dispersion (0.42), a thin rim, and a legibility scrim on the title and the controls (3.5:1, 7:1 under Increase Contrast).
- The pebbles and the arc pass behind the bevel, so the frost's blur and the dispersion show.
- Cost: the frost pyramid is rebuilt each frame while the pebbles drift (30 times a second); under Reduce Motion nothing ticks.
- Met: frost, bevel bending and fringes at the bevel, a guaranteed-contrast title. Approximated: a pale pebble under the text band makes a small gray smudge where the scrim darkens it to keep the contrast; the rainbow arc is soft, not a prism.

## Captures

`docs/evidence/captures/gw-29-study-*.png`, iPhone 18 Pro simulator. The three "vs native" captures are full size and include the real `UIGlassEffect` capsule at the bottom; the "half" captures are half size (reduce transparency, right-to-left, increase contrast).

## Not done in this pass

Dynamic Type at the largest sizes, the accessibility audit, iPad and landscape captures, full-frame M5 characterization, and the vessel study and the final versus rows (a later agent).
