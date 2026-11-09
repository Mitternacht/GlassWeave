import GlassWeave
import GlassWeaveUIKit
import UIKit

/// A colored glow for the laboratory's custom panel, chosen at launch with
/// `-lab.glow <name>` (GW-17). Without the argument the panel has no glow
/// and renders exactly as before.
///
/// Every preset keeps the middle see-through (center opacity 0) and keeps
/// its inner glow within the panel's 22-point rim, where the laboratory
/// places no text, so the tint's legibility rule still describes the area
/// the text sits on.
enum LabGlow: String, CaseIterable {
    /// One warm color, lit from the top edge.
    case amber
    /// A four-stop angular gradient, lit evenly all around.
    case aurora

    /// From the `lab.glow` launch argument, or `nil` for no glow.
    static var fromLaunchArguments: LabGlow? {
        UserDefaults.standard.string(forKey: "lab.glow").flatMap(LabGlow.init(rawValue:))
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
        }
    }
}
