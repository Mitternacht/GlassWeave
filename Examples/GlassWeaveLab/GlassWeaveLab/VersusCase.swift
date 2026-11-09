import GlassWeave
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
        var glow: GlassGlow
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

    /// The custom side's glass with its interior moving or still.
    func weaveParameters(animated: Bool) -> GlassParameters {
        var parameters = weave
        if !animated {
            parameters.interior.speed = 0
        }
        return parameters
    }

    /// Whether this row's custom glass has an interior that moves.
    var animates: Bool { weave.interior.isAnimated }
}

extension VersusCase {
    /// The rows, top to bottom. They use only what GlassWeave ships today:
    /// the colored rim, inner glow, center fill, halo, light direction and
    /// animated interiors.
    static let all: [VersusCase] = [
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
                    haloRadius: halo, haloIntensity: 0.7
                )
            ),
            weave: GlassParameters(
                cornerRadius: cornerRadius, bezelWidth: 16, refraction: 0.7, edgeHighlight: 0.5,
                glow: GlassGlow(
                    colors: [warm, magenta],
                    rimWidth: 2, rimSoftness: 2, rimIntensity: 1,
                    innerGlowRadius: 26, innerGlowIntensity: 0.7,
                    centerOpacity: 0.42, lightAngle: 0, directionality: 0.2,
                    haloRadius: halo, haloIntensity: 0.7
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
                    haloRadius: halo, haloIntensity: 0.8
                )
            ),
            weave: GlassParameters(
                cornerRadius: cornerRadius, bezelWidth: 18, refraction: 0.85, edgeHighlight: 0.5,
                glow: GlassGlow(
                    colors: [aqua, violet],
                    rimWidth: 2, rimSoftness: 2, rimIntensity: 1,
                    innerGlowRadius: 22, innerGlowIntensity: 0.55,
                    centerOpacity: 0, lightAngle: 0, directionality: 0.4,
                    haloRadius: halo, haloIntensity: 0.8
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
                    haloRadius: halo, haloIntensity: 0.9
                )
            ),
            weave: GlassParameters(
                cornerRadius: cornerRadius, bezelWidth: 16, refraction: 0.75, edgeHighlight: 0.6,
                glow: GlassGlow(
                    colors: [gold],
                    rimWidth: 2.5, rimSoftness: 2, rimIntensity: 1,
                    innerGlowRadius: 30, innerGlowIntensity: 0.85,
                    centerOpacity: 0.08, lightAngle: 300, directionality: 0.9,
                    haloRadius: halo, haloIntensity: 0.9
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
                    haloRadius: halo, haloIntensity: 0.8
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
                    haloRadius: halo, haloIntensity: 0.8
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
    static let nativeDetail = String(localized: "UIGlassEffect and its one tint.")
    static let nativeBetter = String(localized: "Does better: bends live content behind it, standard touch response, system integration.")
    static let weaveHeading = String(localized: "GlassWeave glass")
    static let weaveDetail = String(localized: "Custom Metal glass.")
    static let weaveAdds = String(localized: "Adds: hues inside the material, glows that reach inward, animated interiors.")
    static let animateInterior = String(localized: "Animate interiors")
}
