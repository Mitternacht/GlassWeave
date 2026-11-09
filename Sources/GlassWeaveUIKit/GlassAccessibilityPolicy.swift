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
    /// Reduce Motion is on. A glow's pulse stops at its mean level (see
    /// ``GlassAccessibilityPolicy``); the app owns its source's motion and
    /// should stop nonessential movement there.
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
/// | Reduce Transparency | The panel keeps its frame and corner radius but becomes an opaque surface: no refraction, no edge illumination, and a tint of ``opaqueSurfaceTint(for:)`` at full strength. A glow keeps only its rim, as a crisp, evenly lit, steady band at most ``reducedTransparencyRimWidth`` wide, at its own intensity; its inner glow, center fill, halo, and pulse are removed, so the body is exactly the opaque surface and nothing animates. Native content on it keeps its behavior. |
/// | Increase Contrast (`accessibilityContrast == .high`) | A glow keeps its rim, evenly lit (directionality 0) as a clearer boundary, and loses its inner glow and center fill, so the interior is exactly the glass without a glow and the legibility rule for its tint still holds for text. Its halo (outside the shape, behind no text) and pulse are kept. |
/// | Reduce Motion | A glow's pulse stops: the rim, inner glow, and halo stay at the pulse's mean level, `1 − pulseDepth / 2` of their opacity, and nothing animates, so ``GlassSurfaceView`` runs no effect clock. ``GlassSurfaceView`` also reports the setting so the app can stop its source's nonessential motion. |
/// | Light, dark, Increase Contrast | The opaque surface color resolves for the surface's traits. For see-through glass, the app keeps text readable by choosing a tint strength with `GlassTint.minimumStrength(forContrast:againstTextLuminance:)` (GlassWeave). |
public enum GlassAccessibilityPolicy {
    /// The widest rim a glow keeps under Reduce Transparency, in points.
    public static let reducedTransparencyRimWidth = 2.0

    /// The panel to draw for `panel` under `settings`, resolved for `traits`.
    public static func presentedPanel(
        for panel: GlassPanel,
        settings: GlassAccessibilitySettings,
        traits: UITraitCollection
    ) -> GlassPanel {
        var presented = panel
        if settings.reduceTransparency {
            presented.parameters.refraction = 0
            presented.parameters.edgeHighlight = 0
            presented.parameters.tint = opaqueSurfaceTint(for: traits)
            presented.parameters.glow = rimOnly(panel.parameters.glow, maximumWidth: reducedTransparencyRimWidth)
        } else if traits.accessibilityContrast == .high {
            presented.parameters.glow = rimOnly(panel.parameters.glow, maximumWidth: nil)
        }
        if settings.reduceMotion {
            presented.parameters.glow = presented.parameters.glow.steadyAtMeanPulseLevel()
        }
        return presented
    }

    /// A glow reduced to its rim, evenly lit, with no inner glow or center
    /// fill. With `maximumWidth` (Reduce Transparency), the rim's whole
    /// extent (width plus softness) becomes a crisp band of at most that
    /// width, and the halo and pulse are removed; without it (Increase
    /// Contrast), they are kept. A glow without colors stays
    /// ``GlassGlow/none``.
    private static func rimOnly(_ glow: GlassGlow, maximumWidth: Double?) -> GlassGlow {
        guard !glow.colors.isEmpty else { return glow }
        var reduced = glow
        reduced.innerGlowIntensity = 0
        reduced.centerOpacity = 0
        reduced.directionality = 0
        if let maximumWidth {
            reduced.rimWidth = min(glow.rimWidth + glow.rimSoftness, maximumWidth)
            reduced.rimSoftness = 0
            reduced.haloRadius = 0
            reduced.pulseDepth = 0
        }
        return reduced
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

extension GlassGlow.ColorStop {
    /// A glow color from a UIKit color, resolved for `traits` (so dynamic
    /// colors follow light, dark, and Increase Contrast) and read as sRGB
    /// components. Alpha is ignored: the glow's intensities set its opacity.
    /// An extended-range component outside 0...1 is kept here and clamped
    /// by the normalization rule when a renderer accepts the glow. Returns
    /// `nil` for a color with no RGB components, such as a pattern color.
    public init?(_ color: UIColor, angle: Double = 0, traits: UITraitCollection) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        self.init(red: Double(red), green: Double(green), blue: Double(blue), angle: angle)
    }
}
#endif
