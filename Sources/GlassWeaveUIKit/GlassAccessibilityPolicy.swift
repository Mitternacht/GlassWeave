#if canImport(UIKit)
import GlassWeave
import UIKit

/// The accessibility settings a glass surface adapts to.
///
/// ``GlassSurfaceView`` reads them from the system by default and can be
/// given fixed values instead (see ``GlassSurfaceView/AccessibilitySettingsSource``),
/// so tests and previews can exercise each setting.
public struct GlassAccessibilitySettings: Hashable, Sendable {
    /// Reduce Transparency is on: draw an opaque, legible surface instead of
    /// see-through glass.
    public var reduceTransparency: Bool
    /// Reduce Motion is on. GlassWeave's panel has no motion of its own; the
    /// app owns its source's motion and should stop nonessential movement.
    public var reduceMotion: Bool

    public init(reduceTransparency: Bool = false, reduceMotion: Bool = false) {
        self.reduceTransparency = reduceTransparency
        self.reduceMotion = reduceMotion
    }

    /// The system's current settings.
    @MainActor
    public static var system: GlassAccessibilitySettings {
        GlassAccessibilitySettings(
            reduceTransparency: UIAccessibility.isReduceTransparencyEnabled,
            reduceMotion: UIAccessibility.isReduceMotionEnabled
        )
    }
}

/// What a glass surface draws under the accessibility settings.
///
/// | Setting | Behavior |
/// | --- | --- |
/// | VoiceOver | The surface is decorative: it and its Metal view expose no accessibility elements, so VoiceOver reaches only the native content placed above it. |
/// | Reduce Transparency | The panel keeps its frame and corner radius but becomes an opaque surface: no refraction, no edge illumination, and a tint of ``opaqueSurfaceTint(for:)`` at full strength. Native content on it keeps its behavior. |
/// | Reduce Motion | Nothing changes in the panel, which never moves on its own; ``GlassSurfaceView`` reports the setting so the app can stop its source's nonessential motion. |
/// | Light, dark, Increase Contrast | The opaque surface color resolves for the surface's traits. For see-through glass, the app keeps text readable by choosing a tint strength with `GlassTint.minimumStrength(forContrast:againstTextLuminance:)` (GlassWeave). |
public enum GlassAccessibilityPolicy {
    /// The panel to draw for `panel` under `settings`, resolved for `traits`.
    public static func presentedPanel(
        for panel: GlassPanel,
        settings: GlassAccessibilitySettings,
        traits: UITraitCollection
    ) -> GlassPanel {
        guard settings.reduceTransparency else { return panel }
        var opaque = panel
        opaque.parameters.refraction = 0
        opaque.parameters.edgeHighlight = 0
        opaque.parameters.tint = opaqueSurfaceTint(for: traits)
        return opaque
    }

    /// The opaque surface under Reduce Transparency: the system's
    /// `secondarySystemBackground` resolved for `traits` (light or dark
    /// appearance, normal or increased contrast), at full strength. System
    /// label colors are designed to be legible on it.
    public static func opaqueSurfaceTint(for traits: UITraitCollection) -> GlassTint {
        let color = UIColor.secondarySystemBackground.resolvedColor(with: traits)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let unit = { (value: CGFloat) in min(max(Double(value), 0), 1) }
        return GlassTint(red: unit(red), green: unit(green), blue: unit(blue), strength: 1)
    }
}
#endif
