import CoreGraphics
import GlassWeave
import UIKit

/// One of the gallery's three element capsules: an original name, an edge
/// color, a two-color fill gradient, and an animated interior (GW-19).
enum GalleryElement: Int, CaseIterable {
    /// Warm red and orange, with rising embers.
    case ember
    /// Golden yellow, with rays from the center.
    case corona
    /// Green to cyan, with swirling energy filaments.
    case eddy

    var name: String {
        switch self {
        case .ember: String(localized: "Ember")
        case .corona: String(localized: "Corona")
        case .eddy: String(localized: "Eddy")
        }
    }

    /// The name in the diagnostics and launch arguments.
    var identifier: String {
        switch self {
        case .ember: "ember"
        case .corona: "corona"
        case .eddy: "eddy"
        }
    }

    /// The glow's two stops: the top (the light side) and the bottom, sRGB.
    var stops: [GlassGlow.ColorStop] {
        switch self {
        case .ember:
            [.init(red: 1.0, green: 0.60, blue: 0.20, angle: 0), .init(red: 0.98, green: 0.22, blue: 0.14, angle: 180)]
        case .corona:
            [.init(red: 1.0, green: 0.90, blue: 0.40, angle: 0), .init(red: 1.0, green: 0.62, blue: 0.10, angle: 180)]
        case .eddy:
            [.init(red: 0.40, green: 1.0, blue: 0.82, angle: 0), .init(red: 0.15, green: 0.66, blue: 1.0, angle: 180)]
        }
    }

    /// The edge color the floor reflects: the stop at the bottom.
    var edgeColor: GlassGlow.ColorStop { stops[1] }

    var interiorEffect: GlassInterior.Effect {
        switch self {
        case .ember: .embers
        case .corona: .rays
        case .eddy: .energy
        }
    }

    /// The interior's ramp, faintest to brightest, sRGB.
    var interiorColors: [GlassInterior.Color] {
        switch self {
        case .ember:
            [.init(red: 0.80, green: 0.10, blue: 0.04), .init(red: 1.0, green: 0.48, blue: 0.08), .init(red: 1.0, green: 0.88, blue: 0.40)]
        case .corona:
            [.init(red: 0.95, green: 0.50, blue: 0.05), .init(red: 1.0, green: 0.82, blue: 0.22), .init(red: 1.0, green: 0.97, blue: 0.82)]
        case .eddy:
            [.init(red: 0.05, green: 0.38, blue: 0.62), .init(red: 0.20, green: 0.92, blue: 0.85), .init(red: 0.90, green: 1.0, blue: 0.97)]
        }
    }

    /// The selected interior's intensity: the energy filaments are brighter
    /// than embers or rays at the same value, so they get less.
    var interiorIntensity: Double {
        switch self {
        case .ember: 0.95
        case .corona: 0.9
        case .eddy: 0.7
        }
    }

    var seed: UInt32 {
        switch self {
        case .ember: 11
        case .corona: 3
        case .eddy: 7
        }
    }
}

/// The gallery's glass, as functions of animated levels. Lengths are points;
/// coefficients are normalized. Every glow keeps a see-through middle except
/// the selected capsule's faint fill, and no text sits on any of this glass.
enum GalleryStyle {
    /// The largest halo any gallery shape uses, which sets how far apart
    /// their quads must be.
    static let capsuleSelectedHalo = 24.0
    static let capsuleCalmHalo = 10.0
    static let knobHalo = 22.0
    static let orbRestHalo = 14.0
    static let orbSurgeHalo = 22.0

    // MARK: Theme toggle knob

    /// The round glass knob: a warm rim light concentrated on its top edge and
    /// a soft halo, warmer and brighter by day, softer at night. `theme` is 0
    /// for light and 1 for dark.
    static func knob(diameter: Double, theme: Double) -> GlassParameters {
        let day = SIMD3(1.0, 0.70, 0.26)
        let night = SIMD3(1.0, 0.80, 0.56)
        let color = mix(day, night, theme)
        return GlassParameters(
            cornerRadius: diameter / 2, bezelWidth: 14, refraction: 0.95, edgeHighlight: 0.7,
            tint: GlassTint(red: mix(1.0, 0.12, theme), green: mix(1.0, 0.13, theme), blue: mix(1.0, 0.22, theme), strength: mix(0.10, 0.18, theme)),
            glow: GlassGlow(
                colors: [.init(red: color.x, green: color.y, blue: color.z)],
                rimWidth: 1.5, rimSoftness: 2.5, rimIntensity: 1,
                innerGlowRadius: 13, innerGlowIntensity: mix(0.6, 0.5, theme),
                centerOpacity: 0, lightAngle: 0, directionality: 0.92,
                haloRadius: knobHalo, haloIntensity: mix(0.8, 0.65, theme)
            )
        )
    }

    // MARK: Element capsules

    /// A capsule at selection level `level`: 0 is calm (a thin rim, a faint
    /// inner glow, a small halo, no interior, a clear dark middle); 1 is
    /// selected (a stronger rim, a deep inner glow, a faint two-color fill, a
    /// wide halo, and the moving interior). In between, every value is
    /// interpolated and the interior fades in, so selecting never jumps.
    static func capsule(_ element: GalleryElement, width: Double, level: Double) -> GlassParameters {
        let s = min(max(level, 0), 1)
        let interior: GlassInterior = s > 0.001
            ? GlassInterior(
                effect: element.interiorEffect, colors: element.interiorColors,
                intensity: element.interiorIntensity * s, speed: 1, seed: element.seed, centerFade: 0.5
            )
            : .none
        return GlassParameters(
            cornerRadius: width / 2, bezelWidth: 14, refraction: 0.75, edgeHighlight: mix(0.3, 0.5, s),
            tint: GlassTint(red: 0.03, green: 0.035, blue: 0.065, strength: 0.42),
            glow: GlassGlow(
                colors: element.stops,
                rimWidth: mix(1.25, 2.5, s), rimSoftness: 2, rimIntensity: mix(0.8, 1, s),
                innerGlowRadius: mix(14, 34, s), innerGlowIntensity: mix(0.3, 0.8, s),
                centerOpacity: 0.16 * s, lightAngle: 0, directionality: mix(0.45, 0.3, s),
                haloRadius: mix(capsuleCalmHalo, capsuleSelectedHalo, s), haloIntensity: mix(0.35, 0.9, s)
            ),
            interior: interior
        )
    }

    // MARK: Energy orb

    /// The orb at energy `level`: 0 rests (a steady cyan-to-violet rim, a
    /// small halo, and the energy interior's still frame); 1 surges (a
    /// brighter rim, a wide halo, a pulse, and moving filaments). The pulse
    /// deepens from level 0.5, so it never starts with a jump. The
    /// interior cannot change speed without its pattern jumping (its phase is
    /// effect time × speed), so it fades out still and fades in moving:
    /// below level 0.5 it is still and dims toward 0.5, above it moves and
    /// brightens from 0.5.
    static func orb(diameter: Double, level: Double) -> GlassParameters {
        let s = min(max(level, 0), 1)
        let interior: GlassInterior
        if s < 0.5 {
            interior = GlassInterior(
                effect: .energy, colors: orbInteriorColors,
                intensity: 0.55 * (1 - 2 * s), speed: 0, seed: 7, centerFade: 0.5
            )
        } else {
            interior = GlassInterior(
                effect: .energy, colors: orbInteriorColors,
                intensity: 0.95 * (2 * s - 1), speed: 1.3, seed: 7, centerFade: 0.3
            )
        }
        return GlassParameters(
            cornerRadius: diameter / 2, bezelWidth: 12, refraction: 0.85, edgeHighlight: 0.6,
            tint: GlassTint(red: 0.03, green: 0.04, blue: 0.09, strength: 0.35),
            glow: GlassGlow(
                colors: [.init(red: 0.35, green: 0.88, blue: 1.0, angle: 0), .init(red: 0.66, green: 0.36, blue: 1.0, angle: 180)],
                rimWidth: mix(1.75, 2.5, s), rimSoftness: 2, rimIntensity: mix(0.9, 1, s),
                innerGlowRadius: mix(12, 20, s), innerGlowIntensity: mix(0.45, 0.75, s),
                centerOpacity: 0, lightAngle: 0, directionality: 0.25,
                haloRadius: mix(orbRestHalo, orbSurgeHalo, s), haloIntensity: mix(0.45, 0.95, s),
                pulsePeriod: 1.4, pulseDepth: 0.5 * max(2 * s - 1, 0)
            ),
            interior: interior
        )
    }

    static let orbInteriorColors: [GlassInterior.Color] = [
        .init(red: 0.22, green: 0.28, blue: 1.0), .init(red: 0.30, green: 0.86, blue: 1.0), .init(red: 0.95, green: 0.98, blue: 1.0),
    ]

    // MARK: Native comparison

    /// The native glass button's glow (GW-14): the selected element's colors,
    /// or the orb's when none is selected; rim and halo only, steady.
    static func nativeGlow(for element: GalleryElement?) -> GlassGlow {
        GlassGlow(
            colors: element?.stops ?? [.init(red: 0.35, green: 0.88, blue: 1.0, angle: 0), .init(red: 0.66, green: 0.36, blue: 1.0, angle: 180)],
            rimWidth: 2, rimSoftness: 2, rimIntensity: 1,
            lightAngle: 0, directionality: 0.5,
            haloRadius: 18, haloIntensity: 0.75
        )
    }

    // MARK: Helpers

    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    static func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
        a + (b - a) * t
    }
}
