import GlassWeave
import UIKit

/// The calm vessel family of the lab (VESSEL): clear glass with the refined thin
/// rim, holding a calm luminous liquid.
///
/// The picture is a clear vessel (the same clean family as the refined button)
/// with a defined liquid level, a thin soft meniscus line, and a body that is
/// brightest and most saturated along the glass wall and the bottom and falls
/// off smoothly toward the level (``GlassFill/pooling``), never a hot core. The
/// liquid's color is one warm, saturated ramp that stops short of white; the
/// internal structure is sparse (no contour sheets in a level, one soft fold at
/// most in a gel) and the bubbles are few and tiny. Every page that shows a
/// vessel builds it from here, so the family resemblance holds.
enum VesselLook {
    static func color(_ red: Double, _ green: Double, _ blue: Double) -> GlassFill.Color {
        GlassFill.Color(red: red, green: green, blue: blue)
    }

    /// Deep amber at the thin edge, a saturated orange in the body and a soft
    /// gold only at the very brightest: no ramp stop is a pale yellow.
    static let amber = [color(0.36, 0.05, 0.01), color(0.95, 0.34, 0.04), color(1.00, 0.60, 0.18)]

    /// Clear glass: the refined lens with a whisper of warm smoke, a soft
    /// contact shadow, and the thin lit rim. The liquid is the only color.
    static func shell(
        corner: Double = 999, bezel: Double, thickness: Double, dark: Bool = true, shadow: Bool = true
    ) -> GlassParameters {
        var parameters = RefinedLook.lens(corner: corner, bezel: bezel, thickness: thickness, dark: dark)
        parameters.tint = GlassTint(red: 0.10, green: 0.09, blue: 0.09, strength: 0.14)
        parameters.lens.dispersion = 0.08
        if shadow {
            var grounding = RefinedLook.enhancedGrounding(dark: dark)
            grounding.drop.opacity = dark ? 0.20 : 0.14
            parameters.grounding = grounding
        }
        return parameters
    }

    /// A level of liquid: a straight, smooth surface (a barely-there swell) with
    /// a small meniscus at the wall, a pooled body, no contour sheets and two or
    /// three tiny bubbles.
    static func level(
        _ level: Double, tilt: Double = 0, colors: [GlassFill.Color] = amber, bubbles: Int = 3, seed: UInt32 = 11,
        amplitude: Double = 0.25, speed: Double = 0.6
    ) -> GlassFill {
        GlassFill(
            region: .level(level: level, tilt: tilt), wallThickness: 4, colors: colors, emission: 1.0, absorption: 0.85,
            sheets: GlassFill.Sheets(count: 0, edge: 0.65), wallLine: 0.35,
            bubbles: GlassFill.Bubbles(count: bubbles, size: 1.5, speed: 0.6, seed: seed),
            surface: GlassFill.Surface(waveAmplitude: amplitude, wavelength: 150, waveSpeed: speed, meniscus: 2.4),
            gloss: 0.3, pooling: 1
        )
    }

    /// A gel body of its own shape: pooled light, at most one soft fold, tiny
    /// sparse bubbles.
    static func gel(
        _ shape: GlassShape, colors: [GlassFill.Color] = amber, wall: Double = 6, folds: Int = 1, bubbles: Int = 3,
        seed: UInt32 = 7, emission: Double = 1.0
    ) -> GlassFill {
        GlassFill(
            region: .gel(shape), wallThickness: wall, colors: colors, emission: emission, absorption: 0.85,
            sheets: GlassFill.Sheets(count: folds, spacing: 26, edge: 0.5, wobble: 0.6), wallLine: 0.35,
            bubbles: GlassFill.Bubbles(count: bubbles, size: 1.8, speed: 0.5, seed: seed),
            gloss: 0.3, pooling: 1
        )
    }
}
