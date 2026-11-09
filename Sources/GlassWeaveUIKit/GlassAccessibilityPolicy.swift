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
    /// Reduce Motion is on. A glow's pulse stops at its mean level and an
    /// interior shows a still frame (see ``GlassAccessibilityPolicy``); the
    /// app owns its source's motion and should stop nonessential movement
    /// there.
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
/// The glow rows below also apply to the rim and halo that
/// ``EnhancedNativeGlassView`` draws around native glass.
///
/// | Setting | Behavior |
/// | --- | --- |
/// | VoiceOver | The surface is decorative: it and its Metal view expose no accessibility elements, so VoiceOver reaches only the native content placed above it. |
/// | Reduce Transparency | The panel keeps its frame and corner radius but becomes an opaque surface: no refraction, no edge illumination, and a tint of ``opaqueSurfaceTint(for:)`` at full strength. A glow keeps only its rim, as a crisp, evenly lit, steady band at most ``reducedTransparencyRimWidth`` wide, at its own intensity; its inner glow, center fill, halo, and pulse are removed, and so is an interior (`GlassInterior`), so the body is exactly the opaque surface and nothing animates. Native content on it keeps its behavior. |
/// | Increase Contrast (`accessibilityContrast == .high`) | A glow keeps its rim, evenly lit (directionality 0) as a clearer boundary, and loses its inner glow and center fill, and an interior is removed, so the interior is exactly the glass without a glow and the legibility rule for its tint still holds for text. Its halo (outside the shape, behind no text) and pulse are kept. |
/// | Reduce Motion | A glow's pulse stops: the rim, inner glow, and halo stay at the pulse's mean level, `1 − pulseDepth / 2` of their opacity. An interior shows its still frame: its speed becomes 0, so it is drawn at interior time 0 whatever the effect time. Nothing animates, so ``GlassSurfaceView`` runs no effect clock. ``GlassSurfaceView`` also reports the setting so the app can stop its source's nonessential motion. |
/// | Inner light (`GlassLight`) | Reduce Transparency removes it. Increase Contrast removes the body light (it would sit behind text) and keeps only the piping, within ``increasedContrastPipingWidth`` of the outline, a clearer boundary like the glow's rim. Reduce Motion gives the still frame: its speed becomes 0, so it is drawn at phase 0 whatever the effect time. |
/// | Thick lens (`GlassLens`) | Reduce Transparency removes it, dispersion included (the panel is the opaque surface). Increase Contrast keeps the lens, whose samples stay within the source's own colors so the legibility bound for text still holds, and removes the chromatic dispersion, which would put colored fringes behind text. Reduce Motion changes nothing: the lens is static. Its ``GlassLens/softness`` goes with it under Reduce Transparency and is kept under Increase Contrast (it only makes the bend gentler). |
/// | Light model (`GlassLighting`) | Reduce Transparency keeps a thin, crisp rim: the Fresnel outline as a contrasting hairline within ``reducedTransparencyRimWidth`` of the outline, with no reflections, specular streak, rim light, chrome or prismatic finish, or bloom (the panel is the opaque surface). Increase Contrast removes the reflections, the specular streak, the rim light, the finish, and the bloom: only the Fresnel outline in the bevel band remains, as a contrasting hairline (evenly lit) that is a clearer boundary. Reduce Motion changes nothing: the light moves only when the app moves it. |
/// | Grounding (`GlassGrounding`) | Reduce Transparency keeps the drop and contact shadows (they ground the opaque surface) and removes the caustic and the inner shadow. Increase Contrast keeps only the contact shadow, at least ``increasedContrastContactOpacity`` dark and ``increasedContrastContactWidth`` points wide, a clearer boundary; the drop shadow, the inner shadow, and the caustic are removed. Reduce Motion changes nothing: grounding is static. |
/// | Shape (`GlassShape`) | Reduce Transparency and Increase Contrast keep the shape: the opaque surface and the contrasting rim follow its outline. Reduce Motion stills a blob's wobble: its speed becomes 0, so it is drawn at wobble time 0 whatever the effect time (a still, slightly irregular outline). |
/// | Frost (`GlassFrost`) | Reduce Transparency presents the frost as none, its scrim included: the body is the opaque surface, no pyramid is built and the existing ones are released. Increase Contrast keeps the blur (it is static, and its colors stay the source's own) and raises a legibility scrim to at least ``increasedContrastScrimRatio`` (7:1) where one is set; the lens dispersion it would otherwise show at the bevel is removed by the lens row. Reduce Motion changes nothing: frost is static. |
/// | Fill (`GlassFill`) | Reduce Transparency presents a flat, opaque fill: one color, with no emission ramp, contour sheets, wall line, bubbles, or waves (``GlassFill/opaque``). Increase Contrast keeps the fill as it is; put no text over a fill, because the sheets and the bubbles sit behind it (the fill has no legibility bound). Reduce Motion stills it: the bubbles stop (speed 0), the waves stop, and a gel's wobble stops, so it is drawn at effect time 0 whatever the effect time. The opaque fill ignores ``GlassFill/richness``. A level fill's slosh is the app's own spring (``GlassFillSlosh``): an app that honors Reduce Motion does not nudge it. |
/// | Touch (`GlassTouch`) | Reduce Transparency removes it (the opaque surface answers a touch only through the native control above it). Increase Contrast removes the ring and the rim gleam, which are decoration that would move or sparkle behind text, and keeps the finger light as the state of the touch. Reduce Motion removes the ring and the fades: the finger light and the gleam show while the finger is down and are gone when it lifts, so nothing animates and ``GlassSurfaceView`` runs no effect clock for it. |
/// | Light, dark, Increase Contrast | The opaque surface color resolves for the surface's traits. For see-through glass, the app keeps text readable by choosing a tint strength with `GlassTint.minimumStrength(forContrast:againstTextLuminance:)` (GlassWeave). |
public enum GlassAccessibilityPolicy {
    /// The widest rim a glow keeps under Reduce Transparency, in points.
    public static let reducedTransparencyRimWidth = 2.0

    /// The widest rim band that light piping keeps under Increase Contrast,
    /// in points.
    public static let increasedContrastPipingWidth = 2.0

    /// The least opacity the contact shadow has under Increase Contrast.
    public static let increasedContrastContactOpacity = 0.45

    /// The least width, in points, the contact shadow has under Increase
    /// Contrast.
    public static let increasedContrastContactWidth = 1.5

    /// The contrast ratio a legibility scrim guarantees at least, under
    /// Increase Contrast (WCAG 2 level AAA for normal text).
    public static let increasedContrastScrimRatio = 7.0

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
            presented.parameters.lens = .none
        }
        if traits.accessibilityContrast == .high {
            presented.parameters.lens.dispersion = 0
        }
        presented.parameters.glow = presentedGlow(for: panel.parameters.glow, settings: settings, traits: traits)
        presented.parameters.interior = presentedInterior(for: panel.parameters.interior, settings: settings, traits: traits)
        presented.parameters.lighting = presentedLighting(
            for: panel.parameters.lighting, bezelWidth: panel.parameters.bezelWidth, settings: settings, traits: traits
        )
        presented.parameters.grounding = presentedGrounding(for: panel.parameters.grounding, settings: settings, traits: traits)
        presented.parameters.light = presentedLight(
            for: panel.parameters.light, bezelWidth: panel.parameters.bezelWidth, settings: settings, traits: traits
        )
        presented.parameters.shape = presentedShape(for: panel.parameters.shape, settings: settings)
        presented.parameters.frost = presentedFrost(for: panel.parameters.frost, settings: settings, traits: traits)
        presented.parameters.fill = presentedFill(for: panel.parameters.fill, settings: settings)
        presented.parameters.touch = presentedTouch(for: panel.parameters.touch, settings: settings, traits: traits)
        return presented
    }

    /// The touch response to draw for `touch` under `settings` and `traits`
    /// (GW-12): none under Reduce Transparency; without the ring and the gleam
    /// under Increase Contrast; without the ring and the fades (a static finger
    /// light and gleam, shown while the finger is down) under Reduce Motion. A
    /// response that draws nothing is kept as it is.
    static func presentedTouch(
        for touch: GlassTouch,
        settings: GlassAccessibilitySettings,
        traits: UITraitCollection
    ) -> GlassTouch {
        guard touch.isActive else { return touch }
        if settings.reduceTransparency {
            return .none
        }
        var presented = touch
        if traits.accessibilityContrast == .high {
            presented.ripple = 0
            presented.gleam = 0
        }
        if settings.reduceMotion {
            presented = presented.withoutMotion
        }
        return presented
    }

    /// The fill to draw for `fill` under `settings` (GW-28): a flat, opaque
    /// fill under Reduce Transparency; still (bubbles, waves and a gel's
    /// wobble at speed 0) under Reduce Motion. Increase Contrast keeps the
    /// fill (put no text over it). A fill that draws nothing is kept as it is.
    static func presentedFill(for fill: GlassFill, settings: GlassAccessibilitySettings) -> GlassFill {
        guard fill.isActive else { return fill }
        var presented = fill
        if settings.reduceTransparency {
            presented.opaque = true
        }
        if settings.reduceMotion {
            presented.bubbles.speed = 0
            presented.surface.waveSpeed = 0
            if case .gel(.blob(var blob)) = presented.region, blob.wobble.isAnimated {
                blob.wobble.speed = 0
                presented.region = .gel(.blob(blob))
            }
        }
        return presented
    }

    /// The frost to draw for `frost` under `settings` and `traits` (GW-24b):
    /// none under Reduce Transparency (the body is opaque, so there is nothing
    /// to see through and no pyramid is built); under Increase Contrast the
    /// same frost with its scrim, where it has one, at least
    /// ``increasedContrastScrimRatio``. Reduce Motion changes nothing.
    static func presentedFrost(
        for frost: GlassFrost,
        settings: GlassAccessibilitySettings,
        traits: UITraitCollection
    ) -> GlassFrost {
        if settings.reduceTransparency {
            return .none
        }
        guard traits.accessibilityContrast == .high, var scrim = frost.scrim else { return frost }
        scrim.contrast = max(scrim.contrast, increasedContrastScrimRatio)
        var presented = frost
        presented.scrim = scrim
        return presented
    }

    /// The shape to draw for `shape` under `settings` (GW-26): the same shape,
    /// with a blob's wobble stilled (speed 0) under Reduce Motion. A shape that
    /// does not move is kept as it is.
    static func presentedShape(for shape: GlassShape, settings: GlassAccessibilitySettings) -> GlassShape {
        guard settings.reduceMotion, case var .blob(blob) = shape, blob.wobble.isAnimated else { return shape }
        blob.wobble.speed = 0
        return .blob(blob)
    }

    /// The light model to draw for `lighting` under `settings` and `traits`
    /// (GW-23): under Reduce Transparency a thin crisp rim, the Fresnel
    /// outline within ``reducedTransparencyRimWidth``; under Increase Contrast
    /// the outline in the bevel band only. In both the reflections, the
    /// specular streak, the rim light, the chrome and prismatic finishes, and
    /// the bloom are removed, so nothing bright or colored sits where text
    /// might. Lighting that is not active is kept as it is.
    static func presentedLighting(
        for lighting: GlassLighting,
        bezelWidth: Double,
        settings: GlassAccessibilitySettings,
        traits: UITraitCollection
    ) -> GlassLighting {
        guard lighting.isActive else { return lighting }
        let reduceTransparency = settings.reduceTransparency
        guard reduceTransparency || traits.accessibilityContrast == .high else { return lighting }
        var presented = lighting
        presented.finish = .dielectric
        presented.reflection = 0
        presented.specular = 0
        presented.rim = nil
        presented.bloom = 0
        // The enhancements (thick-slab shading, polished bands and glints) are
        // decoration that could sit under text: removed with the finish.
        presented.edgeDepth = 0
        presented.banding = 0
        presented.glints = 0
        // The presence (the body's backdrop pickup and lift, the inner edge
        // glow) is decoration too: removed, so the surface reads as before.
        presented.presence = 0
        // A hairline that contrasts with the surface, so the boundary shows
        // on an opaque or white surface too.
        presented.crispOutline = true
        presented.fresnel = max(lighting.fresnel, 0.8)
        if reduceTransparency {
            presented.bandWidth = min(lighting.bandWidth ?? bezelWidth, reducedTransparencyRimWidth)
        }
        return presented
    }

    /// The grounding to draw for `grounding` under `settings` and `traits`
    /// (GW-25): under Reduce Transparency the drop and contact shadows only;
    /// under Increase Contrast the contact shadow only, firmer, as a clearer
    /// boundary. The caustic (colored light) and the inner shadow are removed
    /// in both. Reduce Motion changes nothing. Grounding that is not active is
    /// kept as it is.
    static func presentedGrounding(
        for grounding: GlassGrounding,
        settings: GlassAccessibilitySettings,
        traits: UITraitCollection
    ) -> GlassGrounding {
        guard grounding.isActive else { return grounding }
        let increaseContrast = traits.accessibilityContrast == .high
        guard settings.reduceTransparency || increaseContrast else { return grounding }
        var presented = grounding
        presented.caustic = .off
        presented.inner = .off
        if increaseContrast {
            presented.drop.opacity = 0
            presented.contact.opacity = max(grounding.contact.opacity, increasedContrastContactOpacity)
            presented.contact.width = max(grounding.contact.width, increasedContrastContactWidth)
        }
        return presented
    }

    /// The inner light to draw for `light` under `settings` and `traits`:
    /// none under Reduce Transparency; under Increase Contrast only the
    /// piping, within ``increasedContrastPipingWidth`` of the outline (the
    /// body light is removed, so text keeps the glass's contrast); and the
    /// still frame (speed 0, so phase 0) under Reduce Motion. Light that
    /// draws nothing or does not move is kept as it is.
    static func presentedLight(
        for light: GlassLight,
        bezelWidth: Double,
        settings: GlassAccessibilitySettings,
        traits: UITraitCollection
    ) -> GlassLight {
        if settings.reduceTransparency {
            return .none
        }
        var presented = light
        if traits.accessibilityContrast == .high, light.isVisible {
            presented.body = 0
            presented.pipingWidth = min(light.pipingWidth ?? bezelWidth, increasedContrastPipingWidth)
        }
        if settings.reduceMotion, presented.isAnimated {
            presented.speed = 0
        }
        return presented
    }

    /// The interior to draw for `interior` under `settings` and `traits`:
    /// none under Reduce Transparency or Increase Contrast (it would move
    /// behind text), and the still frame (speed 0) under Reduce Motion. An
    /// interior that draws nothing or does not move is kept as it is.
    static func presentedInterior(
        for interior: GlassInterior,
        settings: GlassAccessibilitySettings,
        traits: UITraitCollection
    ) -> GlassInterior {
        if settings.reduceTransparency || traits.accessibilityContrast == .high {
            return .none
        }
        var presented = interior
        if settings.reduceMotion, interior.isAnimated {
            presented.speed = 0
        }
        return presented
    }

    /// The glow to draw for `glow` under `settings` and `traits`, the glow
    /// rows of the table above. The custom panel
    /// (``presentedPanel(for:settings:traits:)``) and
    /// ``EnhancedNativeGlassView`` share it.
    static func presentedGlow(
        for glow: GlassGlow,
        settings: GlassAccessibilitySettings,
        traits: UITraitCollection
    ) -> GlassGlow {
        var presented = glow
        if settings.reduceTransparency {
            presented = rimOnly(glow, maximumWidth: reducedTransparencyRimWidth)
        } else if traits.accessibilityContrast == .high {
            presented = rimOnly(glow, maximumWidth: nil)
        }
        if settings.reduceMotion {
            presented = presented.steadyAtMeanPulseLevel()
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

extension GlassInterior.Color {
    /// An interior color from a UIKit color, resolved for `traits` (so
    /// dynamic colors follow light, dark, and Increase Contrast) and read as
    /// sRGB components. Alpha is ignored: the interior's intensity sets its
    /// opacity. An extended-range component outside 0...1 is kept here and
    /// clamped by the normalization rule when a renderer accepts the
    /// interior. Returns `nil` for a color with no RGB components, such as a
    /// pattern color.
    public init?(_ color: UIColor, traits: UITraitCollection) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        self.init(red: Double(red), green: Double(green), blue: Double(blue))
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
