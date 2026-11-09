# Proposal: glass beyond native (GW-21 to GW-29)

**Status:** proposal, not approved and not started (written 2026-11-09). The authoritative
checklist is still [tasks/todo.md](../../tasks/todo.md); nothing here is a shipped feature.

**Why this exists.** The user's goal for GlassWeave: Apple's native glass "is only like the
clear liquid gloss behavior" — it cannot show hues inside or let you play with them — and
GlassWeave's own glass should be "way more capable and more visually interesting than what
Apple is doing". The user also shared four reference images of target looks (glowing liquid in
thick glass, a frosted capsule with dispersion, a prismatic ring button, a thick lens pill with
a pooled colored glow). Those images are third-party work and are deliberately **not** in this
public repository; section 0 describes what each one needs. Build original demos that reach that
quality; never copy the references.

**How it was made.** Read-only research (Apple's documented glass API surface; public routes
for bending app content), four independent design proposals (optics, color and play, liquid
motion, the reference looks), a synthesis, and a skeptical review whose corrections are applied
below and listed in the appendix. `[V: …]` marks a claim checked in the named file or Apple
document at the time; `[A]` marks an assumption. Line numbers refer to branch `implement/glow`
around commit `d2b2b0a` and may drift.


**Basis.** Branch `implement/glow` at `d2b2b0a`; GW-17–GW-20 checked in `tasks/todo.md`. The working tree has uncommitted edits in 9 Swift/test files; `Glass.metal` is unchanged. Read-only review: no edits, builds, runs or git writes.

Checked:
- **The four reference images.**
- **Repository files:**
  - `Glass.metal`: the record is 528 B; the light is fixed upper-left; refraction is `maxDisplacement·rim²`; output is opaque.
  - `GlassRenderer.swift`: at most 8 panels; one pipeline; the full record is bound to both stages; later quads win.
  - `BackgroundRenderer.swift`: `bgra8Unorm` holding encoded values; `acquireTarget` runs before the command buffer and encoder are made.
  - `BackgroundFrame.swift`: sources must be `bgra8Unorm_srgb`.
  - `GlassSurfaceView.swift`: `UIUpdateLink` at 30–60 Hz; opaque `MTKView`; `currentRenderPassDescriptor`; tests have no on-screen scene; the producer runs on every draw.
  - `FrameScheduler`: in-flight bound of 2, deferring at the bound.
  - `NativeGlassView.swift:53` uses `.regular`.
  - Frozen baselines: GW05/17/18 only, each defining its own record prefix.
  - `validation.md`: budgets and the unnamed baseline device.
  - Characterization evidence.
- **DocumentationSearch:**
  - `CAMetalDisplayLink` (+ `Update`) and `CAMetalLayer` drawable docs;
  - the ProMotion guide (`CADisableMinimumFrameDurationOnPhone`);
  - `setFragmentBytes` (4 KB);
  - `UIGlassEffect` (+ `Style`) and `UIGlassContainerEffect`;
  - SwiftUI `Glass` (+ `.clear`'s dimming advice), `GlassEffectContainer`, `glassEffectUnion`/`ID`/`Transition`;
  - `layerEffect`;
  - `hdrHeadroomUsageLimit`.

Markers: `[V: …]` verified in the named file or doc; `[A]` assumption.

**This round delivers:**
- hue placed anywhere inside the glass;
- thick-lens optics with dispersion and inlaid buttons;
- Fresnel, specular, chrome and prismatic finishes from one light;
- variable frost;
- light-mode shadows that do not erase their neighbours;
- organic shapes;
- non-blocking presentation;
- a luminous liquid or gel fill;
- four original showcase screens.

Every step is off by default and byte-identical to today's output when off.

---

## 0. Can we look like this?

How I read the images:
- **Ref 1.**
  - The shells are dark and smoky; the liquid is the only light source.
  - The liquid is a gel body set inside each shell. It follows the shell's curve and has no horizontal level.
  - Layered inner sheets have bright edges.
  - A thin orange line runs in the shell wall: light carried into the glass.
  - Gray studio-strip reflections sit on the rims, and bubbles carry their own highlights.
- **Ref 2.**
  - A third-party before/after mockup; the black left half is "before".
  - The rainbow arc sits inside the frosted capsule *body*. It is the iridescent object behind, frosted, not bevel dispersion.
  - There is a thin bright outline.
- **Ref 3.**
  - Mostly neutral chrome studio bands on a thin ring, with small prismatic glints at the left and right.
  - The plate and the neighbouring pill are embossed; the pill's text has a soft shadow.
  - The ring button sits about 8 pt from the pill.
- **Ref 4:**
  - The top inner edge shows a folded, mirrored band (inverted pink triangles).
  - A faint ghost of the "00:01" digits appears near the top.
  - The lower-left white ellipse has a warm fringe.
  - The bottom pool runs orange → pink → magenta → violet → cyan.
  - The round button is a thick dome with a double rim, and it **overlaps** the pill's right end.

| Ref | What it needs | Delivered by | Verdict for iPhone in real time |
|---|---|---|---|
| 1. Liquid in glass | Dome/pebble shells; smoky tint (exists); Fresnel plus studio arcs; gel fill seen through the shell's refraction, with layered sheets, caustic edges, inner wall line and bubbles; light piping; bloom; HDR-bright lines | GW-21, 22, 23, 26, 27, 28. EDR is **Later** | **Same material family, visibly stylized.** Not reachable: true 3D silhouettes and parallax, back-face and multi-bounce reflections, volumetric scattering, real caustics, depth of field. White-hot lines are SDR white plus bloom until EDR. Target: **one 240 pt vessel at 60 Hz** on the baseline device. Two or three vessels only at `.balanced` or on newer devices. 120 Hz is not a goal [A: no device data]. |
| 2. Frosted capsule with dispersion | Capsule (exists); circular bevel; uniform frost with grain; 6-tap bevel dispersion; Fresnel rim; legibility scrim for large white text | GW-22, 23, 24 | **Close** for a static screen. The iridescent object, and the rainbow arc seen through the body, must be drawn by the app's producer. Glass seen through GlassWeave glass is **Later**. |
| 3. Prismatic ring button, light mode | Circle (exists); ring profile; chrome studio bands; prismatic glints; milky tint; drop, contact and inner shadows that composite over close neighbours; native glyph and text shadow | GW-22, 23, 25 | **Yes, closest of the four.** The embossed plate is drawn by the producer. A chrome "+" glyph needs a glyph-mask input (Later); we use a native SF Symbol. |
| 4. Lens pill with pooled glow | Wide circular bevel with fold; light frost with a clear rim; dispersion on magnified highlights; top specular streak and outline; 4-stop pooled light; a dome button **inlaid** in the pill's height field | GW-21, 22, 23, 24, 25 | **Close.** The button is a bump of the same glass piece, not a separate object refracting the pill (stacking, Later). Not in this round: the ghost label reflection (glyph mask, Later) and EDR glow. Static, so one draw per change; a flowing pool runs at 60 Hz. |

All four looks assume an app-owned background, which is GlassWeave's source contract. Sources are 8-bit sRGB `bgra8Unorm_srgb` [V: BackgroundFrame.swift:60-70]. None of the looks can bend live UIKit content behind the glass; see §1.

---

## 1. Where Apple's glass stops

| Capability | Native glass, iOS 26–27 public API | GlassWeave custom today | After this round |
|---|---|---|---|
| Color in the material | One uniform `tintColor` / `Glass.tint` [V: DocumentationSearch] | Uniform tint; 1–4 stop angular rim glow; interiors | Pooled, arc, point and 4-corner light fields, flowing on the effect clock (GW-21) |
| Clear middle, colored edges | Cannot [V by API] | Yes (GW-17) | Yes, plus light piping (GW-21) |
| Blur amount | Two styles: `.regular` and `.clear`; SwiftUI adds `.identity` [V] | None (one sample per pixel) [V: Glass.metal] | Continuous, per-shape frost (GW-24) |
| Refraction, lens shape | System-defined [V by absence] | Rim only, fixed `rim²` [V] | Profiles, thickness, IOR, fold, inlaid bumps (GW-22) |
| Light, highlights | No public control [V by absence] | Fixed upper-left edge light ≤ 25% to white, plus a separate glow light angle [V] | One movable light: Fresnel, specular, studio environment, chrome and prismatic finishes, bloom (GW-23) |
| Dispersion | No control; unknown whether drawn [A] | None | 3- or 6-tap (GW-22) |
| Glow, HDR | Nothing inside the material [A] | SDR rim, inner glow, halo, pulse | SDR soft knee and bloom (GW-23); EDR Later |
| Light-mode depth | System-defined | The halo washes out on white [V: glow.md] | Drop, contact and inner shadows; caustic (GW-25) |
| Shapes | SwiftUI: any `Shape` [V]; UIKit: `cornerConfiguration` | Rounded rectangle [V] | Ellipse, squircle, blobs (GW-26) |
| Content inside | None [V by API] | Flat interiors | Liquid and gel fill (GW-28) |
| Morph and merge | **Native can**: `GlassEffectContainer`, `UIGlassContainerEffect`, union, IDs, transitions [V] | Cannot | Still cannot; GW-26 lays the field, GW-13 comes next |
| Touch response | `isInteractive` [V] | None | Still none (GW-12 after GW-27) |
| Tilt | No API [V by absence] | None | Light-offset API (GW-23); tilt Later |
| What it can bend | **Any live content behind it** | Only the app texture [V] | Unchanged |
| App GPU cost | Rendered by the system; app GPU cost unmeasured [A] | App pays; the main thread can wait up to 1 s for a drawable [V] | Wait removed (GW-27); tiers |
| Accessibility | Automatic, including the user's look preference (no public API found to read it) [V by search] | Reduce Transparency, Increase Contrast, Reduce Motion policy | Policy extended to every new effect, applied after tiers |
| Standard components | Automatic | Custom surface only | Unchanged |

No new glass or backdrop API turned up for iOS 27 (semantic search, so likely, not proven).

**Still cannot after this round:**
- bend arbitrary live content;
- composite over UIKit (the surface is opaque) [V];
- morph with system springs;
- give the standard touch response;
- follow the look preference;
- appear on standard bars;
- cost the app nothing.

**Plan for bending app content (later rounds):**
1. **A transparent, premultiplied overlay** for hues over anything, without bending (`isOpaque = false`). Premultiplied output with alpha below color behaves additively [A: untested in Core Animation].
2. **App media with full optics:** placed mapping (today aspect-fill only [V: SourceUVTransform]); images; video through `AVPlayerItemVideoOutput` and `CVMetalTextureCache`; Core Image into the producer's command buffer.
3. **A SwiftUI `layerEffect` backend (GW-15b).** UIKit-backed views "may not render" there [V].
4. **Opt-in snapshots** for static UIKit screens.
5. **Frostfield** via FF-12 and GW-16.

**No practical public route:**
- Live pixels of arbitrary views behind us. `CABackdropLayer` is private and forbidden. ReplayKit's in-app capture needs user consent and returns our own composited output late [A].
- Protected video frames.
- Shaders inside Liquid Glass.

---

## 2. Next round

### Order and why

| # | Task | Size | Refs | Why here |
|---|---|---|---|---|
| GW-21 | Inner light fields and the material bench | M | 4, 1 | The user's core complaint. ALU only. Freezes the baseline and builds the bench. |
| GW-27 | Non-blocking presentation, pacing, tiers | M | all | **Parallel from day one** (UIKit host). Must land before GW-24, GW-28, GW-12 and GW-13, because it changes when the drawable arrives. |
| GW-22 | Thick-lens optics, dispersion, inlays | L | 1–4 | The largest visual jump. Introduces the shape-field interface with a C1 depth. |
| GW-23 | Light model, finishes, bloom | M | 1, 3, 4 | Needs GW-22's normal. |
| GW-25 | Light-mode depth (shadow pre-pass) | S | 3, 4 | Needs GW-23's light. |
| GW-24 | Frost | L | 2, 4 | Needs GW-27's acquisition model; wired to GW-22. Its pyramid pass can be prototyped earlier. |
| GW-26 | Freeform shapes | M | 1, 2 | Plugs new fields into GW-22's interface; foundation for GW-13. |
| GW-28 | Liquid and gel fill | L | 1 | Needs GW-21, 22, 23, 26, 27. |
| GW-29 | Studies and the versus screen | M | all | Staged as each look completes. |

Dependencies:
- GW-21 → GW-22 → GW-23 → GW-25.
- {GW-21, GW-27} → GW-24, wired to GW-22.
- GW-22 → GW-26.
- {GW-21, 22, 23, 26, 27} → GW-28.
- Everything → GW-29.
- GW-27 → GW-12, GW-13.

`Glass.metal` is a shared hot file, so shader tasks run in series.

Existing IDs:
- The touch ripple is **GW-12**; the merge is **GW-13**.
- **GW-15** (SwiftUI adapter) and **GW-16** (external textures) are Later.
- GW-27's result feeds the **GW-11** decision record and closes GW-04 item 3.

### Rules that apply to every task
1. **Off by default.** Default output is byte-identical to the frozen `GlassBaselineGW20.metal` (created in GW-21; it is the GW-19 shader, which GW-20 left unchanged [V: architecture.md:210-212]), on My Mac readback. The frozen file defines its own record types, like the existing baselines [V: GlassBaselineGW18.metal].
2. **Normalization.** Every new field documents its unit, range and default, and follows the `GlassParameters` rule: non-finite values are rejected with an error naming the field, finite ones clamped, angles reduced, lists capped. The renderer reports what it drew.
3. **CPU mirror.** It matches readback within one 8-bit step outside the 1 px antialiasing band, at scales 2 and 3. Filter widths are analytic: no `dfdx`/`fwidth` in terms the mirror must match. Use `precise::` functions where fast-math would break the one-step bound.
4. **GPU record.**
   - Append-only, size-asserted in C, MSL and Swift, with a distinctive-value round trip.
   - **The full record stays bound to both vertex and fragment stages.** Frozen baselines read it as a prefix in both [V: GlassRenderer.swift:304-314].
   - Under 4 KB per `set*Bytes` call [V]; about 1.6–1.9 KB at the end of the round [A].
5. **Pipelines.**
   - Built at initialization as function-constant variants (base, optics, liquid); the variant that drew each panel is reported.
   - Creation time is recorded on the Mac; a device item if it exceeds 50 ms [A].
   - Never compiled in the draw path.
6. **Accessibility.**
   - Policy rows and UIKit tests on the iPhone 18 Pro simulator.
   - The policy is applied after the quality tier.
   - The effect clock runs only while something visibly moves; Reduce Motion gives a still frame.
7. **Cost.**
   - M5 characterization: `RenderMetrics`, 3 runs × 3,600 frames, GW-09 workload, pooled p95 increment over the GW-20 glow mode.
   - No-regression checks use interleaved A/B runs in one session, with threshold max(0.05 ms, measured run-to-run spread).
   - Targets are provisional; misses are recorded.
8. **Mutation testing.** One mutation per key test, reverted.
9. **Captures.** Simulator captures of our own renders are inspected and committed. Device items stay open.
10. **Overlap.** Panel quads must not overlap. A debug report (`GlassRenderer`, package access) lists overlapping quads, and every study asserts it is empty.

---

### GW-21: Inner light fields and the material bench

**Outcome:** Colored light lives anywhere inside the glass (pooled along an edge, along an arc, as an orb, or as a 4-corner field) and flows slowly, while the middle stays exactly clear.

**Description:**

`GlassParameters.light` (`GlassLight`, default `.none`) holds up to 4 emitters.

- **Placements:**
  - `.band(angle:reach:)`: a half-plane in panel unit space, so it works for any GW-26 shape;
  - `.arc(angle:span:reach:)`;
  - `.point(x:y:radius:stretch:)`;
  - `.field(corners:warp:)`: bilinear, warped by one octave of `gw_noise2`.
- **Color:** up to 4 stops along the tangent, in linear light (the glow color model).
- **Composite modes:**
  - `.light`: screen, never darkens; the default.
  - `.paint`: source-over at a capped opacity, so it shows on white.
- **Light piping:** the bevel band near an emitter glows in its color, falling off with Euclidean distance from the emitter. Euclidean, not arc length, so it works for any shape. It uses the `bezelWidth` band until GW-22.
- **Center fade:** the same as the interiors'.
- **Motion:**
  - flow, hue drift and drift, computed on the CPU per draw;
  - locked to `GlassInterior.loopDuration` = 64 s [V: GlassInterior.swift:117];
  - ALU only, skipped when there are no emitters.
- **Legibility:** `GlassLegibility` gains a bound on the most light that can be added inside a rect.
- **Accessibility:**
  - Increase Contrast: body light removed; piping within 2 pt of the outline.
  - Reduce Transparency: removed.
  - Reduce Motion: phase 0.

**Foundations:**
1. Freeze the current `Glass.metal` as `GlassBaselineGW20.metal`, with frozen record types.
2. **Material bench** (`-lab.bench <page>`) with procedural 8-bit sRGB backgrounds:
   - a **dot grid** for measuring displacement by centroid (a UV-coded ramp cannot resolve sub-pixel offsets in 8 bits [V: BackgroundFrame.swift:60-70]);
   - a checkerboard;
   - color ribbons;
   - a charcoal stage;
   - light paper.

**Dependencies:** GW-17 to GW-20. **Scope:** M, about 9 files plus tests.

**Acceptance criteria:**
- [ ] The API is documented and normalized; at most 4 emitters and 4 stops; `GlassRenderer.panel` reports the light drawn.
- [ ] `.none` is byte-identical to `GlassBaselineGW20.metal`: four GW-05 sets plus a glow-and-interior case, on a gradient and a checkerboard.
- [ ] Band light does not increase with distance from its edge and is exactly 0 beyond `reach`. `.light` never lowers a channel. Nothing changes outside the outline.
- [ ] With center fade 1, pixels deeper than the fade end are byte-identical to light-off output.
- [ ] Stops and the whole image match the CPU model within one step.
- [ ] Piping: the nearest bevel pixel is brighter than the farthest, and the ratio is within 5% of the CPU model.
- [ ] `t` and `t + 64/speed` are byte-identical, with no seam at the wrap. Hue drift ≤ 16 turns per 64 s.
- [ ] Reduce Motion gives identical frames and no effect clock (controlled-clock UIKit test).
- [ ] `.paint` over white changes relative luminance by ≥ 0.2 at an opacity where `.light` changes it by < 0.02.
- [ ] The extended legibility bound holds on 1,000 seeded backgrounds. Reduce Transparency and Increase Contrast pass UIKit tests.
- [ ] Every bench background renders; captures inspected.
- [ ] M5 increment for 4 emitters plus piping ≤ +0.15 ms p95.
- [ ] **Device only:** cost; light and dark visual check.

**Verification:** Swift Testing readback on My Mac under Metal API Validation; mutations; UIKit and lab UI tests on the iPhone 18 Pro simulator.

**Likely files:**
- `Sources/GlassWeave/GlassLight.swift` (new), `GlassParameters.swift`, `GlassPanelGeometry.swift`, `GlassLegibility.swift`, `Shaders/Glass.metal`
- `GlassWeaveShaderTypes.h`, `GlassAccessibilityPolicy.swift`
- `Tests/GlassWeaveTests/GlassLightTests.swift`, `Shaders/GlassBaselineGW20.metal`
- `Examples/GlassWeaveLab/GlassWeaveLab/MaterialBenchViewController.swift`, `BenchBackgrounds.metal`

---

### GW-22: Thick-lens optics, chromatic dispersion and inlays

**Outcome:** Panels read as solid glass. Content magnifies and bends hard toward the outline, domes magnify, rings stand up at the edge, bright edges split into fringes, and a dome button can sit *on* a pill as part of the same glass.

**Description:**

**Shape-field interface (rounded rectangle in this task).**
- `(distance, normal, lensDepth, inscribedRadius)`.
- `lensDepth` is C1: an interior distance whose iso-contours keep a corner radius of at least the bevel, the same field `normalRadius` already uses [V: GlassPanelGeometry.swift:16-19]. Without it, height creases along the corner diagonals once the bevel is wider than the corner.
- GW-26 adds field kinds behind this interface.

**`GlassParameters.lens` (`GlassLens`):**
- `.rim` (default; exactly the GW-05 code; uses `refraction` and `bezelWidth`);
- `.circular`, `.squircle(exponent:)`, `.chamfer`;
- `.dome` (bevel = inscribed radius);
- `.ring(center:width:)`;
- plus thickness, IOR 1.0–2.4, `maximumOffset` and `allowsFold`.
- For non-`.rim` profiles, `bezelWidth` is the bevel width and `refraction` is ignored (documented).

**The math:**
1. `h = H·s(t)`, `t = lensDepth/bevel`.
2. `N = normalize(n·H·s′/bevel, 1)`; the slope is clamped near the outline.
3. `T = refract(−z, N, 1/ior)`; offset = `T.xy/(−T.z)·h`, clamped to `maximumOffset`.
4. **No fold:** the sampled depth `d + offset(d)` is monotonic only if `offset′(d) ≥ −1 + ε`. GW-05 satisfies this because `|offset′| ≤ refraction ≤ 1` [V]. The CPU computes a per-panel scale to keep the condition, which caps magnification at 1/ε.
5. **Minimum feature width:** profile features narrower than 2 px are widened, so thin rings do not alias in refraction.

**Dispersion** (`lens.dispersion` 0…1; `.threeTap` or `.sixTap`, weights summing to white in linear light):
- per-wavelength only where the R–B spread exceeds 0.25 px;
- every tap keeps the valid-rect clamp.

**Inlays** (`lens.inlays`, at most 2): a `.dome` or `.ring` bump at a position in panel points, with its own radius, profile and rim line. It adds height to the panel's field, so a button sits on a pill in one panel and one pass, with no overlapping quads.

**Pipelines:** function-constant variants, `base` (exactly GW-20) and `optics`, switched per panel. The full record stays bound to both stages (rule 4).

**Accessibility:**
- Reduce Transparency: no lens, dispersion or inlays.
- Increase Contrast: the lens is kept (samples stay in 0…1 [V: GlassLegibility doc]); dispersion goes to 0.

**Dependencies:** GW-21. **Scope:** L, three commits (lens, dispersion, inlays), about 10 files plus tests.

**Acceptance criteria:**
- [ ] `.rim` with dispersion 0 and no inlays is byte-identical; `base` is reported.
- [ ] IOR 1.0 gives the unrefracted background within one step.
- [ ] Each profile matches the CPU mirror within one step, excluding the antialiasing band and slope-clamped pixels.
- [ ] Dot-grid centroids: the offset never exceeds `maximumOffset`. With `allowsFold == false` the mapping is monotonic along normal lines: a CPU property test over 10,000 panels, plus readback of 50.
- [ ] No corner crease: across each corner diagonal, the second difference of the decoded offset is ≤ 2× its value off the diagonal, for bevel = 1, 2 and 4× the corner radius.
- [ ] Dome at IOR 1.5 over a checkerboard: center magnification within 5% of the CPU value.
- [ ] Finite outputs over IOR 1.0–2.4 and thickness 0–64 pt.
- [ ] Dispersion 0 is byte-identical to the lens; spread < 0.25 px is byte-identical at any strength.
- [ ] Gray stays gray, and white stays neutral in `.sixTap` (≤ 1 step).
- [ ] B/W edge: R–B separation within 0.5 px of the CPU (per-channel 50% crossing). No magenta from outside the valid rect.
- [ ] Inlay: height and offset are C0 across the inlay's base; its quad is unchanged; it is byte-identical outside its radius plus 1 px.
- [ ] Pipeline census: all built at initialization; creation time recorded.
- [ ] Base-variant cost, interleaved A/B ≤ max(0.05 ms, spread).
- [ ] M5 targets: lens ≤ +0.10 ms; 3-tap ≤ +0.10 ms; 6-tap ≤ +0.20 ms.
- [ ] Bench captures: dome marble, capsule, ring, fold on/off, dispersion bar, pill with an inlaid dome.
- [ ] Temporal stability on the Mac: over a source translated in 1/8 px steps, frame-to-frame RMS change at fold pixels is recorded and ≤ 2× the unfolded rim's.
- [ ] **Device only:** cost; visual shimmer sign-off.

**Verification:** As in GW-21, plus property tests.

**Likely files:**
- `Sources/GlassWeave/GlassLens.swift`, `GlassShapeField.swift` (new), `GlassParameters.swift`, `GlassPanelGeometry.swift`, `GlassRenderer.swift`
- `Shaders/Glass.metal`, `Shaders/GlassOptics.h`
- `GlassWeaveShaderTypes.h`, `GlassAccessibilityPolicy.swift`
- `Tests/GlassWeaveTests/GlassLensTests.swift`, `GlassDispersionTests.swift`, `ShaderLayoutTests.swift`

---

### GW-23: Light model: Fresnel, specular, studio reflections, chrome and prismatic rims, bloom

**Outcome:** Glass catches light from **one** movable light: a Fresnel outline, a specular streak, studio reflections, chrome or prismatic thin rims, and SDR bloom around the brightest lines.

**Description:**
- `GlassParameters.lighting` (`GlassLighting`, default `.legacy`, byte for byte today's highlight). It has a key light and an optional rim light: azimuth (0 = top, clockwise), elevation, color, intensity, size.
- **One light:** with non-legacy lighting, the glow's light direction follows the key light unless the glow sets `lightAngle` explicitly (documented). Today two independent lights exist [V: Glass.metal:17; GlassGlow].
- **Model:**
  - Schlick Fresnel with `F0` from the IOR;
  - `reflect` into an analytic studio environment: sky/horizon/ground plus ≤ 3 softboxes, with light and dark presets;
  - normalized Blinn-Phong whose lobe is widened by an **analytic** pixel footprint from profile curvature and display scale (no derivatives, rule 3).
- **Finishes:**
  - `.dielectric`;
  - `.chrome(tint:)`;
  - `.prismatic(spread:saturation:phase:)`: thin-film palette in the rim band, weighted by Fresnel, composited source-over.
- **SDR soft knee:** identity below 0.8, a C1 shoulder above it.
- **Analytic bloom:** an optional falloff around specular and caustic lines (distance-based, same pass, never darkens), reaching at most a set width.
- `GlassRenderer.setLightOffset(azimuth:elevation:)` applies per draw.
- **Legibility:** reflections, specular and bloom stay in the bevel band unless the extended CPU bound covers them.
- **Accessibility:**
  - Increase Contrast: bevel band only, evenly lit, no bloom.
  - Reduce Transparency: thin rim only.

**Dependencies:** GW-22. **Scope:** M, about 7 files plus tests.

**Acceptance criteria:**
- [ ] `.legacy` is byte-identical.
- [ ] At `N.z = 1` the reflected fraction equals `F0` (1e-3 CPU; one step GPU; black source, white environment), increasing monotonically to the outline.
- [ ] Specular peak on a dome within 2° of the light azimuth and 1 px of the CPU radius, for 8 azimuths.
- [ ] A 90° light rotation rotates a circular panel's image over a uniform source within one step (panel centered on a pixel corner).
- [ ] Prismatic:
  - hue at 12 angles within 2° of the CPU, for 3 film values;
  - deeper pixels byte-identical;
  - darkest band ≥ 1.3:1 on white.
- [ ] Knee monotonic and C1; outputs finite and ≤ 1. Bloom never lowers a channel and is exactly 0 beyond its width.
- [ ] `setLightOffset` changes only light terms and rejects non-finite values.
- [ ] Glow light follows the key light when not set explicitly (test).
- [ ] Legibility holds over 1,000 backgrounds; Increase Contrast and Reduce Transparency UIKit tests pass.
- [ ] M5 ≤ +0.15 ms p95. "Light studio" captures in light and dark.
- [ ] **Device only:** chrome ring sign-off; cost.

**Verification:** As in GW-21.

**Likely files:**
- `Sources/GlassWeave/GlassLighting.swift` (new), `GlassRenderer.swift`, `GlassPanelGeometry.swift`, `GlassLegibility.swift`, `GlassGlow.swift`
- `Shaders/Glass.metal`, `GlassOptics.h`, `GlassWeaveShaderTypes.h`, `GlassAccessibilityPolicy.swift`
- `Tests/GlassWeaveTests/GlassLightingTests.swift`

---

### GW-24: Frost: variable blur with a per-shape frost map

**Outcome:** A shape can be clear, frosted, or both (clear center with frosted rim, or frosted body with a crisp rim), and a label on it can be guaranteed a contrast ratio.

**Description:**

**Pyramid:**
- 4–5 levels from 1/2 to 1/32 resolution in destination space, as one mipmapped texture.
- Format `rgba16Float`, or `rg11b10Float` if render-target support is confirmed on the simulator [A].
- Covers the union of frosted quads, grown by `maximumOffset + 3σ`.
- Built by a custom 13-tap downsample through `SourceUVTransform` and the valid-rect clamp.

**Ordering (needs GW-27):**
- The pyramid is encoded in the draw's command buffer before the render pass.
- Today a non-provided command buffer is created *after* `acquireTarget` [V: BackgroundRenderer.swift:257-272], so this task moves command-buffer creation ahead of the frost encode.
- If no target is available and the command buffer was not provided, nothing is committed and the cache entry is invalidated. With GW-27's display link the drawable arrives first, so the pyramid is simply encoded before the render pass.

**Resources:**
- A renderer-owned ring of up to 3 pyramids with completion handlers. The public `draw` has no in-flight bound [V: GlassRenderer.swift:22-25].
- If no pyramid is free, the draw takes a defined skip (reason named in API review) and never waits.
- Cached by frame ID + region + target size + maximum σ.
- **Rule for producers:** a producer whose content did not change returns `nil`, or the app uses `setSource`. Otherwise every effect tick produces a new frame [V: GlassSurfaceView.swift:405-414] and rebuilds the pyramid.
- Released while the surface is hidden, through a renderer trim call the host makes.

**Shader:**
- `σ(p)` from the profile (`.uniform`, `.clearCenter`, `.clearRim`, vertical ramp) plus an optional thickness term.
- LOD = `log2(σ/σ₀)`; a B-spline 4-tap per level, two levels blended, at the lens-refracted position.
- **With dispersion, 6 single taps at the shared LOD** (not 6 × 4).
- Below `σ₀` it falls back to the single-sample path.
- Static grain; saturation and brightness in linear light.

**Legibility scrim:** `GlassFrost.legibility(text:contrast:rect:)` is the **last** stage before dither and encode, after all light terms. It applies the minimal per-pixel darkening or lightening, targeting 1.03× the ratio.

**Metrics and docs:** `pyramidBuilds`, `pyramidReuses`, `frostMemoryBytes`; `architecture.md` updated.

**Accessibility:**
- Reduce Transparency: frost presented as `.none`. The body is already opaque [V: GlassAccessibilityPolicy.swift:57-61], so no pyramid is built.
- Increase Contrast: scrim ratio 7:1 where set.

**Dependencies:** GW-21, GW-27; wired to GW-22. **Scope:** L, about 9 files plus tests.

**Acceptance criteria:**
- [ ] `.none` is byte-identical with `frostMemoryBytes == 0`; the same under Reduce Transparency.
- [ ] Uniform source stays uniform; mean luminance on noise (away from valid-rect edges) within 1/255.
- [ ] Dot: anisotropy < 1.15, fitted σ within 15%; step-edge spread monotonic in radius.
- [ ] `.clearCenter` deep pixels byte-identical to unfrosted.
- [ ] No magenta from outside the valid rect.
- [ ] Static source plus pulsing glow: 0 rebuilds in 120 ticks after the first; a new frame ID causes exactly 1. A producer returning `nil` causes 0.
- [ ] Red/blue alternating `.encoded(in:)` frames show their own frame in the frost.
- [ ] A host ignoring the bound (10 draws, none completed) never waits and never writes a pyramid in use (completion-handler audit).
- [ ] A target-unavailable skip commits nothing for a non-produced draw.
- [ ] Scrim on 1,000 backgrounds meets the ratio with all light terms on; outside pixels unchanged.
- [ ] White stays neutral with `.sixTap` plus frost.
- [ ] No texture allocation in the draw path after warm-up (internal counter; the simulator reports 0 for allocation sizes [V: milestone-1.md]).
- [ ] Memory: `frostMemoryBytes` equals the computed bound. GW-09 panel plus full-screen sheet totals stay within the ≤ 64 MiB budget [V: validation.md:117], or the overage is recorded with a reason.
- [ ] Temporal stability on the Mac over a sub-pixel-scrolling source, recorded per radius.
- [ ] M5: pyramid build ≤ +0.15 ms (moving), 0 when static; sampling ≤ +0.30 ms; full-screen sheet recorded.
- [ ] **Device only:** cost at 60 Hz; shimmer sign-off.

**Verification:** As in GW-21; property tests for the pyramid.

**Likely files:**
- `Sources/GlassWeave/GlassFrost.swift`, `FrostPyramid.swift`, `Shaders/Frost.metal` (new)
- `BackgroundRenderer.swift`, `GlassRenderer.swift`, `RenderMetrics.swift`, `Shaders/Glass.metal`
- `Tests/GlassWeaveTests/GlassFrostTests.swift`, `docs/architecture.md`

---

### GW-25: Depth cues for light mode: shadows and colored caustics

**Outcome:** On light pages the glass sits on the surface with drop, contact and inner shadows and a colored caustic, even when neighbours are close.

**Description:**
- `GlassParameters.grounding` (`GlassGrounding`):
  - drop: offset from the key light, blur, spread, opacity, color;
  - contact: 1–3 pt;
  - inner: away from the light;
  - caustic: offset, radius, intensity, color.
- All analytic from the field (erfc edge).
- **Pre-pass:**
  - After the background and before every panel body, one blended quad per panel draws its drop and contact shadow (multiply blend) and its caustic (additive, capped).
  - Blending happens on the encoded `bgra8Unorm` target [V: BackgroundRenderer.swift:71-75], so the shadow is applied in encoded space and documented that way. Multiply in encoded space approximates linear multiply [A: sRGB toe error to be measured].
  - Body quads do **not** grow for shadows, so a neighbour's shadow never erases an earlier body.
  - Each body applies its own shadow to its outer antialiasing ring with the same encoded-space formula, and evaluates its own shadow and caustic at the refracted position inside.
  - Other panels' shadows under a body are not seen (documented).
- The light comes from GW-23.
- **Accessibility:**
  - Reduce Transparency: drop and contact kept, caustic removed.
  - Increase Contrast: contact shadow kept, caustic removed.

**Dependencies:** GW-23. **Scope:** S–M, about 6 files plus tests.

**Acceptance criteria:**
- [ ] Off is byte-identical, with no pre-pass draw.
- [ ] Shadows never raise a channel; caustics never lower one (white, gray, colored sources).
- [ ] Darkening centroid opposite the key azimuth within 3°.
- [ ] Seam: on a uniform background, the step across the body's quad edge and across the outline is ≤ 1 step.
- [ ] Two buttons 8 pt apart with 16 pt drop shadows: neither body loses a pixel versus drawing it alone (readback).
- [ ] Every changed pixel lies inside the CPU pre-pass quad or body quad; the CPU mirror (encoded-space blend) matches within one step.
- [ ] M5 ≤ +0.10 ms. "Paper desk" capture.
- [ ] **Device only:** light-mode check.

**Verification:** As in GW-21.

**Likely files:**
- `Sources/GlassWeave/GlassGrounding.swift` (new), `GlassRenderer.swift` (pre-pass pipeline), `GlassPanelGeometry.swift`
- `Shaders/Glass.metal`, `Shaders/Grounding.metal`
- `GlassWeaveShaderTypes.h`, `GlassAccessibilityPolicy.swift`
- `Tests/GlassWeaveTests/GlassGroundingTests.swift`

---

### GW-26: Freeform shapes: ellipses, squircles and smooth blobs

**Outcome:** Glass takes organic forms, and **every** effect follows the outline, GW-17/18/19/21 included.

**Description:**
- `GlassParameters.shape` (`GlassShape`):
  - `.roundedRectangle` (default, exact path);
  - `.ellipse`;
  - `.superellipse(exponent: 2…10)`;
  - `.blob([Primitive] ≤ 6, smoothness:)`, where a primitive is a circle, a capsule or a rotated rounded box;
  - optional loop-locked wobble.
- Polynomial smooth-min with the blended gradient; distance renormalized by gradient length; a C1 `lensDepth` for GW-22.
- **Port the earlier stages:**
  - glow, halo and light normals currently come from a rounded-rect field with `glowNormalRadius`, and angles from `panelHalfSize` [V: Glass.metal:125-144]; they move to the generic field;
  - the interior depth fraction uses the inscribed radius.
- The CPU computes quad bounds and the inscribed radius (sampled for blobs), which `.dome` uses. `reachesTarget` uses the same bounds.
- Merging across panels remains GW-13.

**Dependencies:** GW-22. **Scope:** M, about 7 files plus tests.

**Acceptance criteria:**
- [ ] `.roundedRectangle` is byte-identical, glow and interior included.
- [ ] Circle and capsule distances within 1e-4 px on the CPU and one step on the GPU.
- [ ] Outline within 0.5 px of the mirror over 360 directions; ellipse area within 0.5% of πab.
- [ ] Neck smoothness: the normal angle changes ≤ 3° between adjacent pixels across smooth-union necks. A two-circle union with a circular lens over a checkerboard has no jump > 2 steps on the bisector.
- [ ] Glow rim, halo and light piping on a blob match the CPU within one step.
- [ ] Antialiasing ramp 1 px; wobble periodic and still under Reduce Motion; every covered pixel inside the CPU quad.
- [ ] M5: 6-primitive blob ≤ +0.15 ms. "Pebble garden" capture.
- [ ] **Device only:** cost.

**Verification:** As in GW-21.

**Likely files:**
- `Sources/GlassWeave/GlassShape.swift` (new), `GlassShapeField.swift`, `GlassPanelGeometry.swift`, `GlassParameters.swift`
- `Shaders/GlassOptics.h`, `Shaders/Glass.metal`, `GlassWeaveShaderTypes.h`
- `Tests/GlassWeaveTests/GlassShapeTests.swift`

---

### GW-27: Non-blocking presentation, frame pacing and quality tiers (closes GW-04 item 3)

**Outcome:** No GlassWeave draw stalls the main thread waiting for a drawable. Interaction frames can request up to 120 Hz while ambient motion stays calm, native views over moving glass stay in step, and a quality setting trades extras for frame time.

**Description:**

**0. Spike first (1–2 days)** [A: each point is unverified]:
- Does `CAMetalDisplayLink` deliver updates on the iOS 27.2 simulator and on My Mac?
- Is `MTLCommandBuffer.present(_:)` accepted with a link's drawable? (Docs say only timed presents assert [V].)
- Does the link follow its layer's display?
- Does pause/resume give one update promptly?

If any answer is no, use the fallback.

**1. Presentation.**
- A `CAMetalLayer` host driven by `CAMetalDisplayLink`, whose update carries the drawable [V].
- `preferredFrameLatency` is 1 or 2 [V].
- Paused when nothing is pending; resumed on request. Unused drawables are released.
- **Effect time** comes from `targetPresentationTimestamp` [V], through the existing clock seam. It replaces the separate `UIUpdateLink`.
- **Fallback:** a render thread calling `nextDrawable()`. This makes `FrameProducer` `@Sendable` and off-main, **a public API change** [V: GlassSurfaceView.swift:102-105]; it goes to API review.
- `allowsNextDrawableTimeout = false` is not a fix: it waits indefinitely [V].
- **UIKit sync:** decide between `presentsWithTransaction` [V: ProMotion guide] and unsynchronized presentation, and record the measured skew between a native view and its panel during a scripted drag. The `waitUntilScheduled` requirement is [A].
- The result is recorded for GW-11.

**2. Pacing:**
- The app declares the motion class through API (`beginInteraction()` / `endInteraction()`), because the surface takes no touches [V].
- interaction 80–120 Hz; transition: default; ambient 30–60 [V: GlassSurfaceView.swift:373 at HEAD]; slow 15–30.
- iPhone above 60 Hz needs the app's `CADisableMinimumFrameDurationOnPhone`. It is documented for `CADisplayLink` and `CAAnimation`, and its effect on `CAMetalDisplayLink` is [A]. The lab adds it.

**3. Tiers.**
- `GlassQuality` `.full`, `.balanced` and `.minimal` are fixed reductions (§4), chosen by the app.
- Low Power Mode and thermal notifications downgrade; changes happen between interactions.
- The accessibility policy is applied after the tier.
- No automatic governor: the docs warn about quality/refresh oscillation [V].
- Debug HUD.

**Dependencies:** GW-07, GW-18. No shader dependency; starts day one. Before GW-24, GW-28, GW-12, GW-13. **Scope:** M, about 7 files plus tests.

**Acceptance criteria:**
- [ ] **Fails on today's code first:** a lab UI test (the surface must be on screen; unit-test processes have no scene [V: GlassSurfaceView.swift:480-484]) holds every drawable of the layer, then requests a frame. Before the change, the main thread stalls ≥ 900 ms [V: 1 s timeout]. After it, the main-actor heartbeat's worst lateness is < 50 ms, and the request draws once the drawables are released.
- [ ] On-demand behavior unchanged: GW-07, GW-18 and GW-19 submission tests pass unmodified; 0 submissions when settled, hidden or backgrounded.
- [ ] The frame-rate range follows the declared motion class (UIKit test reading the link's range).
- [ ] Effect time equals the sum of `targetPresentationTimestamp` deltas (controlled clock).
- [ ] Per-tier readback snapshot is fixed. An injected Low Power Mode notification downgrades and restores. Under Reduce Transparency every tier draws the policy's opaque body.
- [ ] Native/panel skew recorded on the simulator for both sync options; the decision is recorded.
- [ ] GW-04 item 3 checked with evidence; DocC failure table and known limitations updated.
- [ ] **Device only:** Instruments trace on a ProMotion iPhone (120 Hz interaction, no acquisition stall); 60 Hz on the baseline device; visual sync sign-off.

**Verification:** Controlled-clock UIKit tests; lab UI tests; spike note and GW-11 decision note.

**Likely files:**
- `Sources/GlassWeaveUIKit/GlassSurfaceView.swift`, `GlassPresentationHost.swift` (new)
- `Sources/GlassWeave/FrameScheduler.swift`, `GlassQuality.swift` (new), `RenderMetrics.swift`
- `Tests/GlassWeaveUIKitTests/PresentationTests.swift`, `Examples/GlassWeaveLab/GlassWeaveLabUITests/PresentationUITests.swift`
- lab `Info.plist`, `docs/decisions/metal-backend.md`

---

### GW-28: Liquid and gel fill: a luminous body inside a glass vessel

**Outcome:** A glass shape holds a glowing liquid or gel with layered inner sheets, bright caustic edges with bloom, bubbles, a lit inner wall, and (in level mode) a surface that sloshes.

**Description:**

`GlassParameters.fill` (`GlassFill`, default `.none`), drawn by its own pipeline variant.

- **Shell:** the panel's shape (GW-26), lens (GW-22) and lighting (GW-23).
- **Region:**
  - `.level(level:tilt:)`: the shell inset by `wallThickness`, below a waved surface line with a meniscus;
  - `.gel(GlassShape)`: its own field in panel points, clipped to the inset shell. This mode matches ref 1.
- **Through the shell:** the fill is evaluated at the **shell-refracted** position, so the wall magnifies and bends it. An inner-wall contour line gets Fresnel.
- **Shading:**
  - fill dome normal (IOR 1.33);
  - Beer–Lambert absorption;
  - emissive ramp of ≤ 3 stops;
  - ≤ 4 contour sheets (iso-offsets of the fill field, noise-perturbed);
  - caustic lines through the soft knee, plus bloom (GW-23);
  - wall piping (GW-21).
- **Bubbles:** ≤ 16, computed on the CPU per draw (as the sparks [V: GlassInteriorModel]); rings with a crescent and a dot, clipped to the fill.
- **Slosh (level mode):** a CPU damped spring driven by the panel velocity the app reports, or fixed gravity; deterministic. Gel mode gets a loop-locked wobble only.
- **Accessibility:**
  - Reduce Motion: still.
  - Reduce Transparency: a flat opaque fill.
  - Increase Contrast: no text over the fill (documented).

**Dependencies:** GW-21, 22, 23, 26, 27. **Scope:** L, about 8 files plus tests.

**Acceptance criteria:**
- [ ] `.none` or level 0 is byte-identical to the shell-only output.
- [ ] Level 1 equals the inset region at pixel centers. No fill pixel is shallower than `wallThickness`. A gel stays inside the inset shell (property test).
- [ ] Waves off: center height = level ± 0.5 px. A 30° vessel tilt settles at −30° ± 0.5°.
- [ ] Shell refraction of the fill matches the CPU within one step (dot-grid fill).
- [ ] Absorption and emission monotonic in thickness (radial readback against the CPU).
- [ ] Bubbles within 0.5 px of the CPU and inside the fill at 1,000 instants.
- [ ] `t` and `t + 64/speed` byte-identical; replaying an input trace reproduces the bytes.
- [ ] After an impulse, settled (< 0.1°) within the CPU time, then the effect clock stops.
- [ ] Reduce Motion and Reduce Transparency UIKit tests pass; CPU mirror within one step.
- [ ] M5 recorded at 120, 240 and 360 pt; target ≤ +1.0 ms at 240 pt.
- [ ] **Device only:** p95 for **one** 240 pt vessel at 60 Hz on the baseline device; visual sign-off.

**Verification:** As in GW-21, plus slosh tests.

**Likely files:**
- `Sources/GlassWeave/GlassFill.swift`, `GlassFillModel.swift`
- `Shaders/GlassFill.metal`, `GlassOptics.h`, `GlassRenderer.swift`, `GlassWeaveShaderTypes.h`, `GlassAccessibilityPolicy.swift`
- `Tests/GlassWeaveTests/GlassFillTests.swift`

---

### GW-29: Material studies and the Apple vs GlassWeave screen

**Outcome:** Four original studies reach the reference quality, and a versus screen shows what native glass cannot do and what it does better.

**Description:**
- **Lab pages:**
  - public API only, procedural backgrounds we write;
  - deterministic scripts;
  - launch arguments `-lab.study vessel|shelf|pearl|pill` and `-lab.versus`;
  - native controls with VoiceOver labels;
  - leading/trailing layout that mirrors in RTL.
- **Static backgrounds** use `setSource`, or a producer that returns `nil` when unchanged (GW-24 rule).
- **Embossed plates and wells** are part of the producer's background, never panels.
- **Every study asserts no overlapping quads** (rule 10).
- **`NativeGlassView` gains `.clear`.** Per Apple's docs, a `.clear` sample gets a dimming layer beneath it [V: SwiftUI `Glass.clear`].
- **Staged delivery:**
  - pearl after GW-25;
  - pill after GW-24 and GW-25 (it uses the GW-22 inlay);
  - shelf after GW-24;
  - vessel after GW-28;
  - versus last.

**Dependencies:** GW-21 to GW-28 (staged). **Scope:** M, about 9 lab files plus UI tests.

**Acceptance criteria:**
- [ ] Each study launches, runs its script, and writes captures at fixed times; two runs agree within one step.
- [ ] Accessibility audit passes in light and dark with only native elements; the largest text size keeps content and targets; the RTL pseudo-language capture mirrors positions.
- [ ] Reduce Motion, Reduce Transparency and Increase Contrast produce their documented variants.
- [ ] 0 submissions when settled, hidden or backgrounded.
- [ ] Versus:
  - same backdrop and layout;
  - the native half's view hierarchy contains a `UIGlassEffect` view and no GlassWeave surface (hierarchy check);
  - GlassWeave panels are clipped at the divider by a scissor rect; native glass by a mask.
- [ ] Full-frame M5 characterization per study, including the producer's own cost.
- [ ] Review note: each reference feature met, approximated or not met; compared locally only.
- [ ] `git ls-files` contains no reference image, crop, traced asset or path to them.
- [ ] **Device only:** recordings; cost per study on the baseline device.

**Verification:** Lab UI tests on the iPhone 18 Pro and iPad Pro 13-inch simulators; human review of captures.

**Likely files:**
- `Examples/GlassWeaveLab/GlassWeaveLab/Studies/*.swift`, `StudyBackgrounds.metal`, `VersusViewController.swift`
- `Sources/GlassWeaveUIKit/NativeGlassView.swift`, `Sources/GlassWeave/GlassRenderer.swift` (scissor)
- `Examples/GlassWeaveLab/GlassWeaveLabUITests/StudyUITests.swift`

---

## 3. Showcase

**Rules:**
- Compositions are original and backgrounds are procedural.
- No third-party names, text, layouts or artwork; ref 2's wordmark and before/after layout are not reused.
- References stay in the scratchpad and are never committed.

### Reference-level studies (GW-29)

| Study | Quality bar | Composition (deliberately different) | Tasks |
|---|---|---|---|
| **Ember vessel** | Ref 1 | One tall smoky pebble on a charcoal stage holding a `.gel` fill, deep crimson to amber. Three contour sheets, about 12 bubbles, studio arcs, an inner-wall line, bloom on caustic edges. A native countdown label sits beside it; the gel shrinks with the countdown. Dragging a native handle tilts the vessel; the gel wobbles. | GW-21, 22, 23, 26, 27, 28 |
| **Prism shelf** | Ref 2 | A media title bar: a wide frosted capsule with a large native title and three SF Symbol buttons. It floats over three drifting iridescent pebbles, which the producer draws with their own thin-film color, on a teal-to-indigo gradient. Six-tap fringes where pebble edges cross the bevel. Scrim 4.5:1. | GW-22, 23, 24 |
| **Pearl dial** | Ref 3 | Light-mode camera-settings card. Three chrome-ring buttons (timer, flash, grid) on an embossed plate **drawn by the producer**, 8 pt from a capsule slider. Prismatic glints; shadows from the pre-pass; a bench light handle. | GW-22, 23, 25 |
| **Tide pill** | Ref 4 | Focus-session pill (leaf symbol and native elapsed time) over a ribbed-ceramic wave field in sand and slate. A three-stop bottom pool (teal → lime → amber) shifts with progress. A thick dome pause button **inlaid at the leading end** of the pill's own glass. Clear rim, light frost, lens stretch at the outline, top specular streak. | GW-21, 22, 23, 24, 25 |

### Bench pages
- **GW-21, Aurora pools:** presets on charcoal and paper; flow on/off.
- **GW-22, Lens bench:** dome, capsule, ring, fold on/off, inlay, dispersion bar over the dot grid and checkerboard.
- **GW-23, Light studio:** draggable light; environment presets; bloom on/off.
- **GW-24, Focus pull:** clear to frosted; profiles; scrim on/off with a contrast readout; memory readout.
- **GW-25, Paper desk:** close neighbours with shadows; caustic.
- **GW-26, Pebble garden.**
- **GW-27, Pacing HUD:** tier switcher; a "hold drawables" stress toggle.
- **GW-28, Level gauge:** `.level` fill following a native slider.

### Apple vs GlassWeave (GW-29)

A wipe divider over one procedural backdrop. Left half: native `.regular`, or `.clear` with its dimming layer, in a `UIGlassContainerEffect` with a tint. Right half: GlassWeave.

Beats:
1. Hues inside the glass.
2. A clear middle with a colored rim.
3. A frost slider.
4. Lens with dispersion.
5. A filled vessel.

Captions state only verified differences: "Native bends any live content; GlassWeave bends only what the app draws." "Native morphs and merges." "Native glass is rendered by the system; GlassWeave uses the app's GPU time."

---

## 4. Risks and budgets

**Measured baseline (M5, offscreen, not device evidence):**
- Workload: 1206×2622 px target, one 320×180 pt panel at 3x.
- **Lab procedural producer plus background pass:** p95 about 0.74–0.77 ms. This is not the background pass alone [V: glow-characterization.md:12-14].
- Panel +0.13 to +0.15 ms; glow +0.26 to +0.27 ms.
- Interiors: energy +0.60, rays +0.32, embers +0.52 ms.
- Baselines drift 0.03–0.06 ms between records [V: interior-characterization.md].

**No iPhone or iPad numbers exist** [V: validation.md, milestone-1.md].
- The baseline device is not yet named. The protocol says "oldest representative device" in the iOS 26 range [V: validation.md:95; Package.swift `.iOS(.v26)`].
- If that is A13-class, scale by about 5–8×; if A15-class, about 3–6× [A].

**Existing budgets these looks are judged against:**
- Comparative GPU p95 (custom − native) ≤ 2.0 ms at 60 Hz [V: validation.md:113].
- Managed resources ≤ 64 MiB [V: validation.md:117].
- 120 Hz is characterization only.

| Look | M5 per frame (estimate) | Baseline iPhone (estimate, A15 to A13) | Against the 2.0 ms budget | Recommended |
|---|---|---|---|---|
| Pearl dial | about 1.0–1.3 ms | about 3–10 ms total; increment about 0.8–2.5 ms | Borderline at `.full` | Static; one draw per change |
| Tide pill | about 1.5–3 ms | about 5–24 ms total; increment about 2.5–18 ms | **Likely exceeds** at `.full` while flowing | Static, or `.balanced` for flow; `.minimal` during a 120 Hz scroll |
| Prism shelf | about 1.5–2.5 ms (pyramid rebuilt each frame while pebbles drift) | about 5–20 ms | **Likely exceeds** at `.full` | 60 Hz `.balanced` on older devices |
| Ember vessel (one vessel) | about 2–3 ms | about 6–24 ms | **Exceeds** at `.full` on A13 [A] | One vessel at 60 Hz; 120 Hz is not a goal |

All [A]: summed task targets scaled by area. The studies' own producers are unmeasured and may dominate.

**GPU cost risks:**
- **Full-surface redraws.** Every tick redraws the producer, the background and all panels [V: GlassRenderer.draw; GlassSurfaceView producer path]. 120 Hz doubles that. Per-cluster surfaces need transparent output (Later).
- **Register pressure.** Function-constant variants, plus an interleaved base-variant check.
- **Frost:**
  - Rebuilds per frame while the source moves.
  - About 3.5 MB per buffer for a GW-09 panel with a 20 pt σ margin; about 8.4 MB per buffer for a full-screen sheet, ring of up to 3 [A: computed].
  - Must fit the 64 MiB budget.
  - Coarse levels shimmer.
- **Magnification and fold** expose source texels; shimmer is bounded by `maximumOffset`.
- **Liquid:** largest shader; own variant; 60 Hz cap.
- **Pipeline creation time** on device is unknown [A].

**Quality tiers (GW-27).** Fixed sets, snapshot-tested; the accessibility policy is applied after them.

| | full | balanced | minimal |
|---|---|---|---|
| Dispersion | 6-tap | 3-tap | off |
| Frost | 1/2-res base, 2 levels × B-spline | 1/4-res base, 1 level × B-spline | one level, 1 tap |
| Lighting | environment + specular + finishes + bloom | Fresnel + specular | legacy |
| Light emitters | 4 | 2 | 1, no flow |
| Fill / interiors | 4 sheets, 16 bubbles | 2 sheets, 8 bubbles | flat fill, no bubbles |
| Effect clock / interaction | 60 / 120 Hz | 60 / 60 Hz | 30 / 60 Hz |

Low Power Mode caps the tier at `.balanced`; the system also lowers refresh there [V: ProMotion guide]. Serious thermal state forces `.minimal`; critical forces `.minimal` at 30 Hz.

**The main-thread drawable wait (GW-04 item 3):**
- **Today:**
  - `render(in:)` acquires through `currentRenderPassDescriptor`, which calls `nextDrawable()`; that waits up to 1 s [V].
  - The two-frame bound defers draws while the GPU is busy, so the stall happens when drawables are held elsewhere (by the display or by references), not while frames are in flight [V: FrameScheduler].
- **Fix:** GW-27.
- **Until then:**
  - effect clock ≤ 60 Hz;
  - no 120 Hz;
  - bound 2;
  - track `targetAcquisitionDuration` p99/max;
  - land GW-27 before GW-24, GW-28, GW-12 and GW-13.
- **UIKit sync:** moving panels under native views can lag one frame until GW-27 decides `presentsWithTransaction`.

**Accessibility:**

| Setting | Removed | Kept or changed |
|---|---|---|
| Reduce Transparency | Lens, inlays, frost (`.none`, no pyramid), dispersion, body light, reflections, bloom, fill (flat band), caustic | Thin crisp rim; drop and contact shadows |
| Increase Contrast | Body light, reflections, dispersion, bloom, caustic | Bevel-band effects, stronger rim, contact shadow; scrim 7:1 |
| Reduce Motion | Flow, drift, hue drift, wobble, slosh, bubbles, tilt | A still frame |

Also:
- Flash safety follows the WCAG 2.3.1 caps.
- `GlassLegibility` is extended; refraction and frost keep samples in 0…1 [V: GlassLegibility doc].
- Surfaces stay decorative for VoiceOver.

**Other risks:**
- The simulator reports zero GPU time and zero allocation sizes [V: validation.md; milestone-1.md].
- `CAMetalDisplayLink` on the simulator is unverified [A].
- EDR on the simulator is unverified [A].
- Device energy is unmeasured.
- Quads must not overlap (rule 10).
- No reference material in the public repository.

---

## 5. Later

1. **EDR highlights.** `rgba16Float` with `wantsExtendedDynamicRangeContent`, clamped to `currentEDRHeadroom`, respecting `hdrHeadroomUsageLimit` [V: UITraitCollection]. Drawables go from about 38 to 76 MB for 3 at 1206×2622; `bgr10_xr` keeps 4 B/px with about 1.25× headroom [A]. Needs a device. First pick.
2. **GW-12, touch ripple and finger light**, after GW-27.
3. **GW-13, merge**, on GW-26's fields.
4. **Glass springs.**
5. **Tilt-driven light** and device gravity (Core Motion; off under Reduce Motion).
6. **Stacked bodies.** Separate glass objects refracting glass, beyond GW-22 inlays; a full-target intermediate of about 12.6 MB.
7. **Label reflections and chrome glyphs** (glyph-mask input).
8. **Content sources and adapters:** overlay, placed mapping, image/video/Core Image, snapshots; GW-15 plus GW-15b `layerEffect`; GW-16.
9. **Advanced color:** mesh fields; OKLab interpolation; absorb blends; ambient pickup from the pyramid; state transitions; touch drops.
10. **A per-pixel text guard** under Increase Contrast, after an accessibility review.
11. **Automatic quality governor** after device data; per-cluster transparent surfaces.
12. **GW-11, the Metal 4 decision**, with GW-27's result.
13. **App-supplied environment textures.**
14. **Framebuffer-fetch composition** so shadows and halos of overlapping panels compose in linear light. Support on the simulator is unverified [A].

Still open and unaffected: **GW-09**, device qualification. Without it no performance claim is qualified.

---

## Appendix: review corrections applied above

**Corrections** (what I checked: the four reference images; the repo at `implement/glow` `d2b2b0a` plus its uncommitted working tree, where 9 Swift/test files are modified but `Glass.metal` is not; and Xcode DocumentationSearch. `[V: …]` means I checked it in the named file or doc. `[A]` means it is an assumption.)

**A. Reference reading and closeness verdicts**
1. **Ref 1's liquid is not a level fill.** It is a gel body set inside the shell and it follows the shell's curve. GW-28's level-plus-tilt model cannot draw it. Add a `.gel` fill mode (the liquid is its own GW-26 field). Draw the liquid at the shell's refracted position, add an inner-wall contour line, and add analytic bloom. [V: ref1]
2. **The "60 Hz for 1–3 vessels" verdict contradicts the draft's own numbers.** The draft gives +1.0 ms per 240 pt vessel on M5; at 3–6× that is 3–6 ms per vessel on an A15. Three vessels plus the background come to about 11–22 ms. The honest target is one vessel at 60 Hz on the baseline device. [A: arithmetic on the draft's estimates]
3. **Overlapping buttons erase the pill.** Ref 4's button overlaps the pill. Where quads overlap the later panel wins and is computed from the background sample. So an overlapping button quad erases the pill under it, and the Tide pill's "dome at the left end" has the same bug. [V: GlassRenderer.swift:14-19; architecture.md:210-216] Fix: add lens inlays to GW-22, so the button is a bump in the pill's own height field.
4. **Shadows make neighbours erase each other.** GW-25 grows the body quad for shadows. Ref 3's ring button sits about 8 pt from its pill, so the two quads overlap and one erases the other. Fix: draw shadows in a blended pre-pass (item 17). Also, the Pearl dial's embossed plate must be drawn by the producer, not as a panel.
5. **Ref 2's rainbow arc is in the capsule body, not the bevel.** GW-22's bevel-only dispersion cannot make it. The producer must draw it as the object's own iridescence, and the frost then softens it. [V: ref2]
6. **SDR "white-hot" lines need bloom.** Under an SDR knee, ref 1's lines become flat white. Add analytic bloom: a falloff around specular and caustic lines, drawn in the same pass. [A]

**B. Apple API claims, checked with DocumentationSearch**
7. **Glass APIs (verified).**
   - UIKit: `UIGlassEffect` has `init(style:)`, `tintColor` and `isInteractive`, with styles `.regular` and `.clear`. `UIGlassContainerEffect` has `spacing`.
   - SwiftUI: `Glass` has `.regular`, `.clear` and `.identity`, plus `.tint` and `.interactive`. Also `GlassEffectContainer`, `glassEffectID`, `glassEffectUnion` and `glassEffectTransition`.
   - The `Glass.clear` docs say to add a dimming layer beneath it. The versus screen's `.clear` half must do that.
8. **`CAMetalDisplayLink` (verified).** `init(metalLayer:)`; `Update.drawable`, `targetTimestamp` (the render deadline) and `targetPresentationTimestamp` (for animation); `preferredFrameLatency` accepts only 1.0 or 2.0; `isPaused`; timed presents assert. The effect time must come from `targetPresentationTimestamp`, not the deadline as the draft says.
9. **Drawable waits (verified).** `allowsNextDrawableTimeout = false` waits indefinitely; `true` returns nil after 1 s. The docs also say that unreleased drawables exhaust the layer. That makes a test that fails on today's code possible (item 24).
10. **`CADisableMinimumFrameDurationOnPhone` (verified).** It is documented for `CADisplayLink` and `CAAnimation`, and iPad Pro does not need it. The docs do not say whether it governs `CAMetalDisplayLink` or `UIUpdateLink` [A]. The system already disables high rates in Low Power Mode and when hot. The docs warn that changing render quality in response to refresh rate can oscillate, which supports "no automatic governor".
11. **Also verified:** `set{Vertex,Fragment}Bytes` is for single-use data under 4 KB. `UITraitCollection.hdrHeadroomUsageLimit` exists. `layerEffect`'s UIKit-backed views "may not render". I found no public API for the user's Liquid Glass look preference (semantic search, so likely rather than proven).
12. **Still unverified [A]:**
    - `CAMetalDisplayLink` behaviour on the iOS simulator;
    - whether `MTLCommandBuffer.present(_:)` is accepted with a display-link drawable;
    - whether the link follows its layer's display;
    - ReplayKit in-app capture is a public route, so "impossible" should read "no practical public route".

**C. Contracts and architecture**
13. **Drop GW-22's vertex-record split.** Every frozen baseline (GW05/17/18) defines its own record and its vertex function reads it as a prefix of the bound buffer. [V: GlassBaselineGW18.metal header; GlassRenderer.swift:304-314] Keep binding the full record to both stages, about 16 KB of copies per draw at 8 panels.
14. **Use a smooth depth for the lens.** Lens depth from the true rounded-rect distance creases along the corner diagonals once the bevel is wider than the corner radius. Use a C1 depth field whose corner radius is at least the bevel, the same trick the existing `normalRadius` uses [V: GlassPanelGeometry.swift:16-19], and test for creases.
15. **State the no-fold rule.** Sampled depth is `d + offset(d)`; it stays monotonic only if `offset′ ≥ −1 + ε`. GW-05 meets this because `|offset′| ≤ refraction ≤ 1`. [V: GlassPanelGeometry.swift:86; Glass.metal:529-532] The CPU must compute a per-panel scale to keep it.
16. **Thin rings alias in refraction, not only in specular.** Set a minimum feature width of 2 px. Derive filter widths analytically, not with `dfdx`/`fwidth`, because the CPU mirror cannot reproduce GPU derivatives. [A]
17. **Shadow pre-pass.** Draw shadows and caustics in a blended pass between the background and the panel bodies. The blends run in encoded space, because the target is non-sRGB `bgra8Unorm` [V: BackgroundRenderer.swift:71-75]. Each body applies its own shadow to its outer antialiasing ring with the same formula. Add a debug report of overlapping quads.
18. **GW-24's ordering is wrong.** When no command buffer is provided, it is created *after* `acquireTarget` [V: BackgroundRenderer.swift:257-272]. On a skip, pyramid-only work must not be committed. GW-27's display link delivers the drawable first, so GW-24 must come after GW-27.
19. **The pyramid ring needs its own completion tracking.** `GlassRenderer.draw` is public and has no in-flight bound [V: GlassRenderer.swift:22-25]. The renderer must track when each pyramid buffer is free, with a fallback that never waits.
20. **Static backgrounds would rebuild the pyramid every tick.** With a producer set, every draw produces a new frame, including every effect-clock tick [V: GlassSurfaceView.swift:405-414]. A producer whose content has not changed must return nil, or the study must use `setSource`.
21. **Frost memory.** The 1.4 MB per panel leaves out the 3σ + offset margin; with it, a 20 pt σ needs about 3.5 MB per buffer [A]. A full-screen sheet needs about 17 MB double-buffered. The managed-resource budget is ≤ 64 MiB [V: validation.md:117], and that budget is incremental; the GW-18 run already showed 62.5 MiB of total device allocation at peak [V: glow-characterization.md]. Options: `rg11b10Float` and freeing the pyramid while hidden.
22. **Reduce Transparency must turn frost off.** It already makes the body opaque [V: GlassAccessibilityPolicy.swift:57-61], so frost must become `.none` there and no pyramid is built.
23. **GW-27 real-host tests must be lab UI tests.** "A test process has no connected scenes, so no surface there is ever on screen" [V: GlassSurfaceView.swift:480-484].
24. **GW-27's two criteria cannot fail meaningfully.**
    - The `MTLSharedEvent` heartbeat test passes on today's code: with 2 frames in flight the scheduler defers, so `nextDrawable` is never called [V: FrameScheduler.swift:102-111].
    - The "drawable source that never yields" test only exercises a stub.
    - Replace both with: hold all of the layer's drawables, then request a frame.
25. **GW-27 contract and UI gaps.**
    - The render-thread fallback changes the public `FrameProducer` contract, which is non-Sendable and called on main today [V: GlassSurfaceView.swift:102-105].
    - The motion class needs an API, because the surface takes no touches [V: GlassSurfaceView.swift:77-80].
    - Native views over moving panels can be a frame out of sync with the Metal frame; decide whether to use `presentsWithTransaction` [V: ProMotion doc tip].
26. **Smaller gaps.**
    - Two light directions already exist [V: Glass.metal:17; GlassGlow]; GW-23 must unify them.
    - Say how the lens relates to `refraction`/`bezelWidth`.
    - Apply the accessibility policy after the quality tier.
    - GW-26 must port the glow, halo and interior normal and angle fields [V: Glass.metal:125-144].
    - Frost with dispersion should be 6 fetches, not 6 × 4.
    - Measure pipeline creation time.

**D. Acceptance criteria**
27. **The UV-coded ramp cannot work.** The source contract accepts only `bgra8Unorm_srgb` [V: BackgroundFrame.swift:60-70], which gives 8 bits per axis. That cannot resolve 0.5 px on a 1206 px target. Use dot-grid centroids instead.
28. **"Base variant within 0.02 ms" is below measurement noise.** Baselines drifted 0.03–0.06 ms between records [V: interior-characterization.md]. Use interleaved A/B runs with the threshold at max(0.05 ms, the measured spread).
29. **Other criteria.**
    - "Below a threshold" criteria need numbers.
    - Shimmer can be measured on Mac readback.
    - In the versus screen, the renderer census cannot show which half a renderer drives; use a view-hierarchy check.
    - Tide pill also needs GW-24 and the GW-22 inlay.
    - Captions must not state [A] claims as fact.
    - Add RTL mirroring.

**E. Cost honesty**
30. **"Background pass alone" is mislabelled.** The 0.74–0.77 ms includes the lab's procedural producer [V: glow-characterization.md:12-14].
31. **Compare against the existing budgets.**
    - The comparative GPU budget is ≤ 2.0 ms at 60 Hz [V: validation.md:113].
    - The baseline device is not named; the protocol says the oldest representative device in the iOS 26 range [V: validation.md:95; Package.swift `.iOS(.v26)`]. That may be A13-class, which means a larger slowdown factor [A].
    - The study producers' own cost is unmeasured.
32. **Housekeeping.**
    - The shader frozen as "GW20" is the GW-19 shader; GW-20 did not change it [V: architecture.md:210-212].
    - `CAFrameRateRange` is at `GlassSurfaceView.swift:373` at HEAD and at line 386 in the working tree.
