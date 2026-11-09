import GlassWeave

/// The Apple-grade starting values the lab's pages share (REFINE).
///
/// Apple's Liquid Glass is a mostly clear body with real edge refraction, a
/// thin crisp rim line that is brighter on the lit side, one soft highlight,
/// calm shadows, and quiet color. Every page builds its panels from these
/// functions and adds only what the page is about (a lens, an inner light, a
/// grounding), so the family resemblance holds everywhere. The values are
/// documented, with the reason for each, in `docs/glass-optics.md`
/// ("Apple-grade defaults").
enum RefinedLook {
    /// The one light direction of the lab: the upper left.
    static let azimuth = 315.0

    /// The refined light model for a dark or a light page.
    static func lighting(dark: Bool, finish: GlassLighting.Finish = .dielectric) -> GlassLighting {
        .refined(azimuth: azimuth, environment: dark ? .studioDark : .studioLight, finish: finish)
    }

    /// A quiet tint: a whisper of the page's own value, so the body is a clear
    /// material and not a colored gel.
    static func tint(dark: Bool, strength: Double = 0.10) -> GlassTint {
        dark
            ? GlassTint(red: 0.62, green: 0.64, blue: 0.70, strength: strength)
            : GlassTint(red: 1, green: 1, blue: 1, strength: strength * 2.5)
    }

    /// A soft, low-contrast shadow for light pages: one drop, the faintest
    /// contact line, no inner shadow and no caustic. On dark pages a shadow
    /// would not show, so there is none.
    static func grounding(dark: Bool) -> GlassGrounding {
        guard !dark else { return .none }
        let ink = GlassGrounding.Color(red: 0.16, green: 0.17, blue: 0.24)
        return GlassGrounding(
            drop: .init(offset: 8, blur: 22, spread: -3, opacity: 0.16, color: ink),
            contact: .init(width: 1, opacity: 0.05, color: ink),
            lightAzimuth: azimuth
        )
    }

    /// A clear panel with edge refraction and the refined rim: the default
    /// shapes are rounded rectangles, capsules and circles.
    static func panel(corner: Double, bezel: Double = 16, dark: Bool) -> GlassParameters {
        GlassParameters(
            cornerRadius: corner, bezelWidth: bezel, refraction: 0.55, edgeHighlight: 0,
            tint: tint(dark: dark), lighting: lighting(dark: dark), grounding: grounding(dark: dark)
        )
    }

    /// A thick lens: it magnifies and bends the edge, and its middle stays
    /// quiet. Dispersion is low and lives at the bevel only (the squircle
    /// profile is flat in the middle, so there is nothing to split there).
    static func lens(corner: Double = 999, bezel: Double = 24, thickness: Double = 24, dark: Bool) -> GlassParameters {
        var parameters = panel(corner: corner, bezel: bezel, dark: dark)
        parameters.lens = GlassLens(
            profile: .squircle(exponent: 3), thickness: thickness, indexOfRefraction: 1.45, maximumOffset: 44,
            allowsFold: true, dispersion: 0.3, dispersionTaps: .threeTap
        )
        return parameters
    }

    // MARK: Enhanced (ENHANCE)

    /// The refined light with its enhancements: a rim that reads as a thick
    /// slab (a deeper far side, a faint inner light on the lit side), and with
    /// a polished finish, reflection stripes and small glints.
    static func enhancedLighting(dark: Bool, finish: GlassLighting.Finish = .dielectric) -> GlassLighting {
        .enhanced(azimuth: azimuth, environment: dark ? .studioDark : .studioLight, finish: finish)
    }

    /// A soft shadow that also shows on dark pages: a broad, low drop in a
    /// deep ink and the faintest contact line, so the glass sits above the
    /// page (the contact shadow is the line the glass casts, not a halo).
    static func enhancedGrounding(dark: Bool) -> GlassGrounding {
        let ink = dark
            ? GlassGrounding.Color(red: 0.02, green: 0.02, blue: 0.06)
            : GlassGrounding.Color(red: 0.16, green: 0.17, blue: 0.24)
        return GlassGrounding(
            drop: .init(offset: dark ? 7 : 8, blur: dark ? 18 : 22, spread: -3, opacity: dark ? 0.30 : 0.18, color: ink),
            contact: .init(width: 1, opacity: dark ? 0.12 : 0.06, color: ink),
            lightAzimuth: azimuth
        )
    }

    /// A panel with edge refraction, the enhanced light and a soft shadow.
    static func enhancedPanel(corner: Double, bezel: Double = 16, dark: Bool) -> GlassParameters {
        var parameters = panel(corner: corner, bezel: bezel, dark: dark)
        parameters.lighting = enhancedLighting(dark: dark)
        parameters.grounding = enhancedGrounding(dark: dark)
        return parameters
    }

    /// A thicker, stronger lens than ``lens(corner:bezel:thickness:dark:)``:
    /// the squircle is rounder (exponent 2.4), so the bending reaches farther
    /// in from the outline, the index is 1.5, and the six-tap dispersion is
    /// visible on a high-contrast edge at the bevel and nowhere else.
    static func enhancedLens(
        corner: Double = 999, bezel: Double = 28, thickness: Double = 30, dispersion: Double = 0.55, dark: Bool
    ) -> GlassParameters {
        var parameters = enhancedPanel(corner: corner, bezel: bezel, dark: dark)
        parameters.lens = GlassLens(
            profile: .squircle(exponent: 2.4), thickness: thickness, indexOfRefraction: 1.5, maximumOffset: 64,
            allowsFold: true, dispersion: dispersion, dispersionTaps: .sixTap
        )
        return parameters
    }

    /// Upgrades a panel the page already built (its finish, tint, frost,
    /// light and shape are kept) to the enhanced look: the thick-slab rim, a
    /// firmer rim line, stripes and glints on a polished finish, a soft shadow
    /// where there is none (`addShadow`), and, for a lens that bends hard at
    /// the bevel, a thicker glass with visible six-tap dispersion. A panel
    /// that is not lit by the refined look is returned as it is.
    static func enhance(_ parameters: GlassParameters, addShadow: Bool = true) -> GlassParameters {
        var p = parameters
        guard p.lighting.look == .refined, !p.fill.isActive else { return p }
        let dark = p.lighting.environment == .studioDark
        p.lighting.edgeDepth = max(p.lighting.edgeDepth, 0.6)
        p.lighting.fresnel = max(p.lighting.fresnel, 0.7)
        p.lighting.specular = max(p.lighting.specular, 0.6)
        if case .dielectric = p.lighting.finish {} else {
            p.lighting.banding = max(p.lighting.banding, 0.6)
            p.lighting.glints = max(p.lighting.glints, 0.6)
        }
        if addShadow, p.grounding == .none {
            p.grounding = enhancedGrounding(dark: dark)
        }
        switch p.lens.profile {
        case .rim, .ring: break
        default:
            p.lens.thickness = min(p.lens.thickness * 1.25, 60)
            p.lens.maximumOffset = max(p.lens.maximumOffset, 64)
            p.lens.dispersion = max(p.lens.dispersion, 0.55)
            p.lens.dispersionTaps = .sixTap
        }
        return p
    }

    /// A polished chrome ring button: a thin ring of glass standing at the
    /// edge, a clear middle, a bright studio reflected in a band with real
    /// stripes (dark wall, bright band, dark band), a faint thin film, and a
    /// few small prismatic glints that turn with the key light.
    static func chromeRing(diameter: Double, azimuth: Double = RefinedLook.azimuth) -> GlassParameters {
        var ring = panel(corner: diameter / 2, bezel: 13, dark: false)
        ring.tint = GlassTint(red: 1, green: 1, blue: 1, strength: 0.05)
        ring.lens = GlassLens(
            profile: .ring(center: 6.5, width: 11), thickness: 14, indexOfRefraction: 1.5, maximumOffset: 16,
            allowsFold: false, dispersion: 0.3, dispersionTaps: .sixTap
        )
        ring.lighting = .enhanced(
            azimuth: azimuth, environment: .studioLight, finish: .prismatic(spread: 1.2, saturation: 0.3, phase: 0.06)
        )
        ring.lighting.fresnel = 0.8
        ring.lighting.specular = 0.7
        ring.lighting.reflection = 0.95
        ring.lighting.banding = 1
        ring.lighting.glints = 0.9
        ring.lighting.bandWidth = 13
        return ring
    }
}
