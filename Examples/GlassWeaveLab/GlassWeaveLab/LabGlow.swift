import GlassWeave
import GlassWeaveUIKit
import UIKit

/// A colored glow for the laboratory's custom panel, chosen at launch with
/// `-lab.glow <name>` (GW-17, GW-18), or for the native reference glass with
/// `-lab.nativeGlow <name>` (GW-14), which draws the same value's rim and
/// halo around Apple's glass. Without the argument the panel has no glow and
/// renders exactly as before, and the reference is plain native glass.
///
/// Every preset keeps the middle see-through (center opacity 0) and keeps
/// its inner glow within the panel's 22-point rim, where the laboratory
/// places no text, so the tint's legibility rule still describes the area
/// the text sits on. A halo lies outside the panel, behind no text.
enum LabGlow: String, CaseIterable {
    /// One warm color, lit from the top edge.
    case amber
    /// A four-stop angular gradient, lit evenly all around.
    case aurora
    /// A warm light concentrated on the top edge, spilling outside the
    /// panel as a halo (GW-18).
    case ember
    /// A cool two-color glow whose rim, inner glow, and halo pulse
    /// (GW-18).
    case energy

    /// From the `lab.glow` launch argument, or `nil` for no glow.
    static var fromLaunchArguments: LabGlow? {
        fromLaunchArguments(key: "lab.glow")
    }

    /// From the launch argument `key` (`lab.glow` for the custom panel,
    /// `lab.nativeGlow` for the native reference, GW-14), or `nil`.
    static func fromLaunchArguments(key: String) -> LabGlow? {
        UserDefaults.standard.string(forKey: key).flatMap(LabGlow.init(rawValue:))
    }

    /// The glow for this preset, with system colors resolved for `traits`
    /// so they follow light, dark, and Increase Contrast.
    func glow(for traits: UITraitCollection) -> GlassGlow {
        switch self {
        case .amber:
            let warm = GlassGlow.ColorStop(.systemOrange, traits: traits) ?? .init(red: 1, green: 0.6, blue: 0.2)
            return GlassGlow(
                colors: [warm],
                rimWidth: 2, rimSoftness: 2.5, rimIntensity: 1,
                innerGlowRadius: 22, innerGlowIntensity: 0.85,
                centerOpacity: 0, lightAngle: 0, directionality: 0.7
            )
        case .aurora:
            let stops: [(UIColor, Double)] = [
                (.systemCyan, 0), (.systemIndigo, 90), (.systemPink, 180), (.systemYellow, 270),
            ]
            return GlassGlow(
                colors: stops.compactMap { GlassGlow.ColorStop($0.0, angle: $0.1, traits: traits) },
                rimWidth: 2, rimSoftness: 2.5, rimIntensity: 1,
                innerGlowRadius: 22, innerGlowIntensity: 0.7,
                centerOpacity: 0, lightAngle: 0, directionality: 0
            )
        case .ember:
            let warm = GlassGlow.ColorStop(.systemOrange, traits: traits) ?? .init(red: 1, green: 0.6, blue: 0.2)
            return GlassGlow(
                colors: [warm],
                rimWidth: 2, rimSoftness: 2.5, rimIntensity: 1,
                innerGlowRadius: 22, innerGlowIntensity: 0.8,
                centerOpacity: 0, lightAngle: 0, directionality: 0.75,
                haloRadius: 28, haloIntensity: 0.9
            )
        case .energy:
            let stops: [(UIColor, Double)] = [(.systemCyan, 0), (.systemPurple, 180)]
            return GlassGlow(
                colors: stops.compactMap { GlassGlow.ColorStop($0.0, angle: $0.1, traits: traits) },
                rimWidth: 2, rimSoftness: 2.5, rimIntensity: 1,
                innerGlowRadius: 22, innerGlowIntensity: 0.75,
                centerOpacity: 0, lightAngle: 0, directionality: 0.2,
                haloRadius: 28, haloIntensity: 0.9,
                pulsePeriod: 1.8, pulseDepth: 0.55
            )
        }
    }

    /// Whether the preset pulses, so the laboratory offers its Pulse switch.
    var pulses: Bool {
        glow(for: UITraitCollection()).pulseDepth > 0
    }
}
