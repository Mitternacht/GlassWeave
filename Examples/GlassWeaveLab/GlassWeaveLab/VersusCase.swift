import GlassWeave
import GlassWeaveUIKit
import UIKit

/// One comparison on the Apple vs GlassWeave screen (GW-29a): the same
/// capsule twice, once as Apple's glass (`UIGlassEffect` with its one tint,
/// and a GlassWeave rim and halo around it, for fairness) and once as
/// GlassWeave's own glass.
///
/// The screen builds one row per entry of ``all``, so a later phase adds a
/// feature (the lens, light, frost, shapes, liquid) with one entry: a title,
/// what each side shows, one sentence about each, and the two styles. Each
/// sentence states only what the code in this repository does or what
/// Apple's public API offers.
struct VersusCase: Identifiable {
    /// What the native half draws for this row: `UIGlassEffect` has one tint
    /// for the whole material; the rim and halo are GlassWeave's GW-14 layers
    /// around it.
    struct Native {
        var tint: UIColor?
        /// GlassWeave's GW-14 rim and halo around the native glass, or `nil`
        /// for the genuine `UIGlassEffect` alone (the refined rows).
        var glow: GlassGlow? = nil
        /// Which public `UIGlassEffect` style the native half uses.
        var style: NativeGlassView.Style = .regular
    }

    /// The panel's height; both halves use it, with the shape a capsule.
    static let panelHeight: CGFloat = 80
    /// The capsule's corner radius, for the custom side's parameters.
    static let cornerRadius = Double(panelHeight / 2)

    let id: String
    let title: String
    /// An SF Symbol shown on the native control in both halves.
    let symbol: String
    /// What the native half does here; one sentence.
    let nativeCaption: String
    /// What the GlassWeave half does here; one sentence.
    let weaveCaption: String
    let native: Native
    /// The custom side's glass, with its interior moving.
    let weave: GlassParameters
    /// The panel's height, in points; both halves use it.
    var height: CGFloat = VersusCase.panelHeight
    /// The custom side's glass on a dark page, for the rows that follow the
    /// appearance (the refined rows); `nil` uses ``weave`` on both.
    var weaveDark: GlassParameters? = nil

    /// The custom side's glass with everything that moves held still when
    /// `animated` is false: the interior, the light's flow, a shape's wobble,
    /// the fill's bubbles and waves.
    func weaveParameters(animated: Bool, dark: Bool = false) -> GlassParameters {
        var parameters = dark ? (weaveDark ?? weave) : weave
        if !animated {
            parameters.interior.speed = 0
            parameters.light.speed = 0
            if case var .blob(blob) = parameters.shape {
                blob.wobble = .none
                parameters.shape = .blob(blob)
            }
            parameters.fill.bubbles.speed = 0
            parameters.fill.surface.waveSpeed = 0
            if case .gel(.blob(var blob)) = parameters.fill.region {
                blob.wobble = .none
                parameters.fill.region = .gel(.blob(blob))
            }
        }
        return parameters
    }

    /// Whether this row's custom glass has something that moves.
    var animates: Bool { weave.interior.isAnimated || weave.fill.isAnimated || weave.shape.isAnimated }
}

extension VersusCase {
    /// The rows, top to bottom: the first four compare the colored rim, inner
    /// glow, light direction and animated interiors (GW-29a); the rest, built
    /// on the refined light model, compare what the later optics, light,
    /// frost, shape and liquid features add.
    static let all: [VersusCase] = glowRows + refinedRows

    /// The first four rows: GlassWeave's glow layers on both halves (the halo
    /// is kept soft, so it reads as light and not as a neon outline).
    private static let glowRows: [VersusCase] = [
        VersusCase(
            id: "hues",
            title: "Hues inside the glass",
            symbol: "paintpalette",
            nativeCaption: "A tint is one color for the whole material. The rim and halo around it are GlassWeave layers.",
            weaveCaption: "A gradient fill from amber to magenta inside the glass, over the same rim and halo.",
            native: Native(
                tint: UIColor(red: 1.0, green: 0.52, blue: 0.14, alpha: 0.55),
                glow: GlassGlow(
                    colors: [warm, magenta],
                    rimWidth: 2, rimSoftness: 2, rimIntensity: 1,
                    lightAngle: 0, directionality: 0.2,
                    haloRadius: halo, haloIntensity: 0.45
                )
            ),
            weave: GlassParameters(
                cornerRadius: cornerRadius, bezelWidth: 16, refraction: 0.7, edgeHighlight: 0.5,
                glow: GlassGlow(
                    colors: [warm, magenta],
                    rimWidth: 2, rimSoftness: 2, rimIntensity: 1,
                    innerGlowRadius: 26, innerGlowIntensity: 0.7,
                    centerOpacity: 0.42, lightAngle: 0, directionality: 0.2,
                    haloRadius: halo, haloIntensity: 0.45
                )
            )
        ),
        VersusCase(
            id: "clear",
            title: "A clear middle, a colored rim",
            symbol: "circle.dashed",
            nativeCaption: "Apple's clear material bends the live content behind it, which GlassWeave cannot. The rim and halo are GlassWeave's.",
            weaveCaption: "The same rim and halo plus an inner glow. The middle stays clear and bends only what the app draws.",
            native: Native(
                tint: nil,
                glow: GlassGlow(
                    colors: [aqua, violet],
                    rimWidth: 2, rimSoftness: 2, rimIntensity: 1,
                    lightAngle: 0, directionality: 0.4,
                    haloRadius: halo, haloIntensity: 0.5
                )
            ),
            weave: GlassParameters(
                cornerRadius: cornerRadius, bezelWidth: 18, refraction: 0.85, edgeHighlight: 0.5,
                glow: GlassGlow(
                    colors: [aqua, violet],
                    rimWidth: 2, rimSoftness: 2, rimIntensity: 1,
                    innerGlowRadius: 22, innerGlowIntensity: 0.55,
                    centerOpacity: 0, lightAngle: 0, directionality: 0.4,
                    haloRadius: halo, haloIntensity: 0.5
                )
            )
        ),
        VersusCase(
            id: "light",
            title: "Light from one side",
            symbol: "sun.max",
            nativeCaption: "The rim and halo can be lit from one side. The inside stays Apple's material.",
            weaveCaption: "The inner glow is lit from the same side and reaches into the glass.",
            native: Native(
                tint: nil,
                glow: GlassGlow(
                    colors: [gold],
                    rimWidth: 2.5, rimSoftness: 2, rimIntensity: 1,
                    lightAngle: 300, directionality: 0.9,
                    haloRadius: halo, haloIntensity: 0.55
                )
            ),
            weave: GlassParameters(
                cornerRadius: cornerRadius, bezelWidth: 16, refraction: 0.75, edgeHighlight: 0.6,
                glow: GlassGlow(
                    colors: [gold],
                    rimWidth: 2.5, rimSoftness: 2, rimIntensity: 1,
                    innerGlowRadius: 30, innerGlowIntensity: 0.85,
                    centerOpacity: 0.08, lightAngle: 300, directionality: 0.9,
                    haloRadius: halo, haloIntensity: 0.55
                )
            )
        ),
        VersusCase(
            id: "interior",
            title: "An animated interior",
            symbol: "flame",
            nativeCaption: "Apple offers no way to draw inside the material. Your views sit on top of it.",
            weaveCaption: "Embers rise inside the glass, drawn with it. They hold still under Reduce Motion or with the switch off.",
            native: Native(
                tint: nil,
                glow: GlassGlow(
                    colors: [ember, flame],
                    rimWidth: 2, rimSoftness: 2, rimIntensity: 1,
                    lightAngle: 0, directionality: 0.3,
                    haloRadius: halo, haloIntensity: 0.5
                )
            ),
            weave: GlassParameters(
                cornerRadius: cornerRadius, bezelWidth: 16, refraction: 0.75, edgeHighlight: 0.5,
                tint: GlassTint(red: 0.05, green: 0.02, blue: 0.04, strength: 0.3),
                glow: GlassGlow(
                    colors: [ember, flame],
                    rimWidth: 2, rimSoftness: 2, rimIntensity: 1,
                    innerGlowRadius: 20, innerGlowIntensity: 0.6,
                    centerOpacity: 0.1, lightAngle: 0, directionality: 0.3,
                    haloRadius: halo, haloIntensity: 0.5
                ),
                interior: GlassInterior(
                    effect: .embers,
                    colors: [
                        .init(red: 0.80, green: 0.10, blue: 0.04), .init(red: 1.0, green: 0.48, blue: 0.08), .init(red: 1.0, green: 0.88, blue: 0.40),
                    ],
                    intensity: 0.95, speed: 1, seed: 11, centerFade: 0.5
                )
            )
        ),
    ]

    // MARK: The refined rows

    /// A row of the refined set. The native half is the genuine
    /// `UIGlassEffect` alone (no GlassWeave rim or halo), with the style and
    /// the one tint Apple's public API offers; the custom half is built for a
    /// light and for a dark page.
    private static func refined(
        id: String, title: String, symbol: String, nativeCaption: String, weaveCaption: String,
        tint: UIColor? = nil, style: NativeGlassView.Style = .regular, height: CGFloat = 96,
        make: (Bool) -> GlassParameters
    ) -> VersusCase {
        VersusCase(
            id: id, title: title, symbol: symbol, nativeCaption: nativeCaption, weaveCaption: weaveCaption,
            native: Native(tint: tint, glow: nil, style: style),
            weave: RefinedLook.enhance(make(false), addShadow: false), height: height,
            weaveDark: RefinedLook.enhance(make(true), addShadow: false)
        )
    }

    /// The refined thick lens with a nearly clear body: the page's own colors
    /// show through, as they do through Apple's clear glass.
    private static func clearLens(corner: Double = 999, bezel: Double, thickness: Double, dark: Bool) -> GlassParameters {
        var parameters = RefinedLook.lens(corner: corner, bezel: bezel, thickness: thickness, dark: dark)
        parameters.tint.strength = 0.05
        return parameters
    }

    private static func fillColor(_ red: Double, _ green: Double, _ blue: Double) -> GlassFill.Color {
        GlassFill.Color(red: red, green: green, blue: blue)
    }

    private static func lightStop(_ red: Double, _ green: Double, _ blue: Double) -> GlassLight.Stop {
        GlassLight.Stop(red: red, green: green, blue: blue)
    }

    private static let refinedRows: [VersusCase] = [
        refined(
            id: "lens", title: "A thick lens with dispersion", symbol: "magnifyingglass",
            nativeCaption: "Apple's clear style bends the live content behind it. Thickness and color split are not settings, and Apple advises a dimming layer over bright content (none here).",
            weaveCaption: "A squircle bevel magnifies the edge and splits color there, with six taps. It bends only what the app draws.",
            style: .clear
        ) { dark in
            var parameters = clearLens(bezel: 34, thickness: 36, dark: dark)
            parameters.lens.dispersion = 0.7
            parameters.lens.dispersionTaps = .sixTap
            return parameters
        },
        refined(
            id: "pooled", title: "Inner light and pooled color", symbol: "lightbulb",
            nativeCaption: "One tint colors the whole material. A color cannot pool at an edge.",
            weaveCaption: "Three colors pool along the bottom edge and fade toward a clear middle.",
            tint: UIColor(red: 0.45, green: 0.55, blue: 1.0, alpha: 0.35), height: 88
        ) { dark in
            var parameters = clearLens(bezel: 22, thickness: 16, dark: dark)
            parameters.light = GlassLight(
                emitters: [
                    GlassLight.Emitter(
                        placement: .band(angle: 180, reach: 1.2),
                        colors: [lightStop(0.22, 0.80, 1.0), lightStop(0.56, 0.48, 1.0), lightStop(1.0, 0.42, 0.70)],
                        intensity: 0.95
                    )
                ],
                composite: dark ? .light : .paint, centerFade: 0.7, piping: 0.4, body: 1, speed: 1
            )
            return parameters
        },
        refined(
            id: "finish", title: "Chrome and prismatic finishes", symbol: "diamond",
            nativeCaption: "Apple's glass has one finish: its own. There is no setting for a metal or a prismatic rim.",
            weaveCaption: "A polished chrome rim whose bright bands carry a thin rainbow, lit from the upper left.",
            height: 88
        ) { dark in
            // A thin polished band at the edge and a clear middle, reflecting a
            // light studio, so the band reads as bright steel with a thin
            // rainbow in its highlights.
            var parameters = RefinedLook.panel(corner: 999, bezel: 18, dark: dark)
            parameters.tint = GlassTint(red: 1, green: 1, blue: 1, strength: 0.05)
            parameters.lens = GlassLens(
                profile: .ring(center: 9, width: 14), thickness: 16, indexOfRefraction: 1.5, maximumOffset: 18,
                allowsFold: false, dispersion: 0.3, dispersionTaps: .sixTap
            )
            parameters.lighting = GlassLighting.refined(
                azimuth: RefinedLook.azimuth, environment: .studioLight,
                finish: .prismatic(spread: 2, saturation: dark ? 0.4 : 0.55, phase: 0.06)
            )
            parameters.lighting.fresnel = 0.9
            parameters.lighting.specular = 0.95
            parameters.lighting.reflection = 1
            parameters.lighting.bandWidth = 18
            parameters.lighting.bloom = dark ? 0.1 : 0.2
            return parameters
        },
        refined(
            id: "frost", title: "Frost with a clear center", symbol: "snowflake",
            nativeCaption: "Apple's regular style blurs what is behind it by an amount the system chooses. There is no frost setting.",
            weaveCaption: "Frosted at the rim and clear in the middle. The profile, blur size and grain are settings.",
            height: 104
        ) { dark in
            var parameters = clearLens(bezel: 24, thickness: 18, dark: dark)
            parameters.frost = GlassFrost(
                profile: .clearCenter, sigma: 12, transition: 22, grain: 0.03, thickness: 0.5, saturation: 1.1, brightness: 1
            )
            return parameters
        },
        refined(
            id: "shape", title: "Freeform shapes", symbol: "hexagon",
            nativeCaption: "Apple's glass takes a corner configuration: rounded rectangles and capsules.",
            weaveCaption: "A smooth union of circles and capsules with a slow wobble. This one is a pebble."
        ) { dark in
            var parameters = clearLens(bezel: 22, thickness: 20, dark: dark)
            parameters.shape = .blob(GlassBlob(
                primitives: [
                    .circle(center: CGPoint(x: -0.55, y: 0.04), radius: 0.80),
                    .capsule(from: CGPoint(x: -0.15, y: 0.12), to: CGPoint(x: 0.55, y: -0.10), radius: 0.62),
                    .circle(center: CGPoint(x: 0.78, y: 0.02), radius: 0.50),
                ],
                smoothness: 0.45, wobble: GlassBlob.Wobble(amplitude: 0.012, speed: 0.4)
            ))
            return parameters
        },
        refined(
            id: "liquid", title: "Liquid fill", symbol: "drop",
            nativeCaption: "Apple's glass has no inside. A tint is one color; anything in it is your own views on top.",
            weaveCaption: "A calm gel lit from inside, with a thin bright edge and a few tiny bubbles, seen through the thick wall.",
            tint: UIColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 0.45), height: 104
        ) { dark in
            var parameters = RefinedLook.lens(corner: 38, bezel: 22, thickness: 20, dark: dark)
            parameters.tint = GlassTint(red: 0.08, green: 0.07, blue: 0.07, strength: 0.34)
            parameters.fill = GlassFill(
                region: .gel(.blob(GlassBlob(
                    primitives: [
                        .capsule(from: CGPoint(x: -0.45, y: 0.08), to: CGPoint(x: 0.45, y: 0.08), radius: 0.50),
                        .circle(center: CGPoint(x: 0.30, y: -0.10), radius: 0.42),
                    ],
                    smoothness: 0.5, wobble: GlassBlob.Wobble(amplitude: 0.008, speed: 0.5)
                ))),
                wallThickness: 5,
                colors: [fillColor(0.34, 0.06, 0.01), fillColor(1.0, 0.40, 0.05), fillColor(1.0, 0.70, 0.30)],
                emission: 0.85, absorption: 0.7,
                sheets: GlassFill.Sheets(count: 1, spacing: 14, edge: 0.3, wobble: 0.2),
                wallLine: 0.4,
                bubbles: GlassFill.Bubbles(count: 3, size: 1.8, speed: 0.6, seed: 5)
            )
            return parameters
        },
    ]

    /// The halo every row uses, in points; it sets the margin around each
    /// panel, so no two panels' quads overlap.
    static let halo = 18.0

    private static let warm = GlassGlow.ColorStop(red: 1.0, green: 0.72, blue: 0.20, angle: 0)
    private static let magenta = GlassGlow.ColorStop(red: 1.0, green: 0.20, blue: 0.55, angle: 180)
    private static let aqua = GlassGlow.ColorStop(red: 0.20, green: 0.95, blue: 0.90, angle: 0)
    private static let violet = GlassGlow.ColorStop(red: 0.62, green: 0.35, blue: 1.0, angle: 180)
    private static let gold = GlassGlow.ColorStop(red: 1.0, green: 0.85, blue: 0.40, angle: 0)
    private static let ember = GlassGlow.ColorStop(red: 1.0, green: 0.60, blue: 0.20, angle: 0)
    private static let flame = GlassGlow.ColorStop(red: 0.98, green: 0.22, blue: 0.14, angle: 180)
}

/// The words around the comparison, in one place so they are easy to check
/// against the code.
enum VersusCopy {
    static let title = String(localized: "Apple vs GlassWeave")
    static let nativeHeading = String(localized: "Apple glass")
    static let nativeDetail = String(localized: "UIGlassEffect: regular or clear style, one tint.")
    static let nativeBetter = String(localized: "Does better: bends live content behind it, standard touch response, system integration.")
    static let weaveHeading = String(localized: "GlassWeave glass")
    static let weaveDetail = String(localized: "Custom Metal glass.")
    static let weaveAdds = String(localized: "Adds: hues inside the material, a thick lens with dispersion, inner light, chrome and prismatic finishes, frost with a clear center, freeform shapes, a liquid fill.")
    static let animateInterior = String(localized: "Animate interiors")
}
