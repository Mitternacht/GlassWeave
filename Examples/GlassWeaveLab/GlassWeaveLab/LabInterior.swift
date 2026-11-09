import GlassWeave
import GlassWeaveUIKit
import UIKit

/// An animated interior for the laboratory's custom panel, chosen at launch
/// with `-lab.interior <name>` (GW-19). Without the argument the panel has no
/// interior and renders exactly as before. It combines with `-lab.glow`
/// (for example `-lab.glow ember -lab.interior embers`, whose sparks rise
/// into the ember halo).
///
/// Every preset keeps the documented center fade (1), so the middle of the
/// panel is exactly the glass without an interior; the panel's title and
/// button sit partly over the faded part. Increase Contrast and Reduce
/// Transparency remove the interior, so the legibility rule still describes
/// the text area there.
enum LabInterior: String, CaseIterable {
    /// Blue-to-white filaments, like a plasma orb.
    case energy
    /// Warm rays and beams from the center, like a sun.
    case rays
    /// Flame tongues from the bottom edge and rising sparks.
    case embers

    /// From the `lab.interior` launch argument, or `nil` for no interior.
    static var fromLaunchArguments: LabInterior? {
        UserDefaults.standard.string(forKey: "lab.interior").flatMap(LabInterior.init(rawValue:))
    }

    /// The interior for this preset, with system colors resolved for
    /// `traits` so they follow light, dark, and Increase Contrast.
    func interior(for traits: UITraitCollection) -> GlassInterior {
        let colors: [UIColor]
        let seed: UInt32
        let intensity: Double
        switch self {
        case .energy:
            colors = [.systemIndigo, .systemCyan, .white]
            seed = 7
            intensity = 0.85
        case .rays:
            colors = [.systemOrange, .systemYellow, UIColor(red: 1, green: 0.97, blue: 0.85, alpha: 1)]
            seed = 3
            intensity = 0.8
        case .embers:
            colors = [.systemRed, .systemOrange, .systemYellow]
            seed = 11
            intensity = 0.9
        }
        return GlassInterior(
            effect: effect,
            colors: colors.compactMap { GlassInterior.Color($0, traits: traits) },
            intensity: intensity, speed: 1, seed: seed, centerFade: 1
        )
    }

    private var effect: GlassInterior.Effect {
        switch self {
        case .energy: .energy
        case .rays: .rays
        case .embers: .embers
        }
    }
}
