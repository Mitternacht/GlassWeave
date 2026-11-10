import Foundation
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

    /// PRESENCE: the level every refined panel of the lab carries
    /// (`GlassLighting.presence`): the body picks up the backdrop's colors
    /// gently and lifts a little, the inner edge glows in the backdrop's hue,
    /// the far side is deeper. It bends nothing.
    static let presence = 0.85

    /// CLEAN: the level every refined panel of the lab carries
    /// (`GlassLighting.clean`): the rim is one smooth gradient, the polished
    /// bands are wide and soft, and the panel is dithered with the triangular
    /// dither. It removes marks and adds none.
    static let clean = 1.0

    /// CLEAN-2: how much of the wide, soft rim the clean look keeps
    /// (`GlassLighting.softRim`). 0, the default, is the thin crisp hairline of
    /// the system glass; the launch argument `-lab.softRim 1` brings back the
    /// first clean pass's soft gradient (the explicit opt-in) on every page.
    static var softRim: Double {
        min(max(UserDefaults.standard.double(forKey: "lab.softRim"), 0), 1)
    }

    /// The refined light model for a dark or a light page.
    static func lighting(dark: Bool, finish: GlassLighting.Finish = .dielectric) -> GlassLighting {
        var lighting = GlassLighting.refined(azimuth: azimuth, environment: dark ? .studioDark : .studioLight, finish: finish)
        lighting.presence = presence
        lighting.clean = clean
        lighting.softRim = softRim
        return lighting
    }

    /// A quiet tint: a whisper of the page's own value, so the body is a clear
    /// material and not a colored gel. PRESENCE: a fifth as strong on dark pages
    /// (0.02 against 0.10): a gray mixed in linear light desaturated the
    /// backdrop under the glass, which read as a gray cast; the backdrop's own
    /// color now comes through, and the presence lifts it. Dark pages carry
    /// 0.02 (a trace).
    static func tint(dark: Bool, strength: Double = 0.02) -> GlassTint {
        dark
            ? GlassTint(red: 0.62, green: 0.64, blue: 0.70, strength: strength)
            : GlassTint(red: 1, green: 1, blue: 1, strength: strength * 10)
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
            tint: tint(dark: dark), lighting: lighting(dark: dark), grounding: grounding(dark: dark),
            dither: .triangular
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
        blend(&parameters.lens)
        return parameters
    }

    /// POLISH: makes a lens's bend subtle and smoothly blended, like Apple's
    /// glass: the soft window (`softness` 1: the bend rises from nothing at
    /// the outline and fades out toward the flat middle with no visible start
    /// line), a smooth ceiling on the offset (`maximumOffset`, by default 7
    /// points), a higher-order squircle (a longer, flatter run out of the
    /// bevel), the index of glass a little lower, and faint fringes. The
    /// thickness is left as it is: it also gives the rim light its slope. A
    /// ring is left alone. Idempotent.
    static func blend(_ lens: inout GlassLens, maximumOffset: Double = 7, dispersion: Double = 0.2) {
        switch lens.profile {
        case .rim, .ring: return
        case let .squircle(exponent): lens.profile = .squircle(exponent: max(exponent, 3.5))
        default: break
        }
        lens.softness = 1
        lens.maximumOffset = min(lens.maximumOffset, maximumOffset)
        lens.indexOfRefraction = min(lens.indexOfRefraction, 1.42)
        lens.dispersion = min(lens.dispersion, dispersion)
    }

    // MARK: Enhanced (ENHANCE)

    /// The refined light with its enhancements: a rim that reads as a thick
    /// slab (a deeper far side, a faint inner light on the lit side), and with
    /// a polished finish, reflection stripes and small glints.
    static func enhancedLighting(dark: Bool, finish: GlassLighting.Finish = .dielectric) -> GlassLighting {
        var lighting = GlassLighting.enhanced(azimuth: azimuth, environment: dark ? .studioDark : .studioLight, finish: finish)
        lighting.presence = presence
        lighting.clean = clean
        lighting.softRim = softRim
        return lighting
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

    /// A lens with the enhanced light, a soft shadow and, as the polish asks,
    /// a bend that is quiet and blended: the squircle is high-order (3.5), the
    /// index 1.42, the offset ceiling 7 points, the six-tap fringes faint
    /// (`dispersion` is capped at 0.25) and at the bevel only.
    static func enhancedLens(
        corner: Double = 999, bezel: Double = 28, thickness: Double = 30, dispersion: Double = 0.55, dark: Bool
    ) -> GlassParameters {
        var parameters = enhancedPanel(corner: corner, bezel: bezel, dark: dark)
        parameters.lens = GlassLens(
            profile: .squircle(exponent: 3.5), thickness: thickness, indexOfRefraction: 1.42, maximumOffset: 7,
            allowsFold: false, dispersion: min(dispersion, 0.25), dispersionTaps: .sixTap, softness: 1
        )
        return parameters
    }

    /// Upgrades a panel the page already built (its finish, tint, frost,
    /// light and shape are kept) to the enhanced look: the thick-slab rim, a
    /// firmer rim line, stripes and glints on a polished finish, a soft shadow
    /// where there is none (`addShadow`), and, for a lens, the blended bend
    /// of ``blend(_:maximumOffset:dispersion:)`` with six-tap fringes. A panel
    /// that is not lit by the refined look is returned as it is.
    static func enhance(_ parameters: GlassParameters, addShadow: Bool = true) -> GlassParameters {
        var p = parameters
        guard p.lighting.look == .refined, !p.fill.isActive else { return p }
        let dark = p.lighting.environment == .studioDark
        p.lighting.edgeDepth = max(p.lighting.edgeDepth, p.lens.profile == .rim ? 0.6 : 0.75)
        p.lighting.presence = max(p.lighting.presence, presence)
        p.lighting.clean = max(p.lighting.clean, clean)
        p.lighting.softRim = softRim
        p.dither = .triangular
        p.lighting.fresnel = max(p.lighting.fresnel, 0.7)
        p.lighting.specular = max(p.lighting.specular, 0.6)
        if case .dielectric = p.lighting.finish {} else {
            p.lighting.banding = max(p.lighting.banding, 0.6)
            p.lighting.glints = max(p.lighting.glints, 0.6)
        }
        if addShadow, p.grounding == .none {
            p.grounding = enhancedGrounding(dark: dark)
        }
        if p.lens.profile != .rim, p.lens.dispersion > 0 {
            p.lens.dispersionTaps = .sixTap
        }
        blend(&p.lens)
        return p
    }

    /// A polished chrome ring button: a chunky ring of glass standing at the
    /// edge (about a third of the radius), a clear middle, a bright studio
    /// reflected in a band with real stripes (a deep dark stripe between
    /// bright ones), a faint thin film, and several small prismatic glints that
    /// turn with the key light.
    static func chromeRing(diameter: Double, azimuth: Double = RefinedLook.azimuth) -> GlassParameters {
        // The ring's proportions follow the diameter (POLISH: chunkier than the
        // first pass, 0.17 of the diameter against 0.13).
        let width = max(diameter * 0.17, 12)
        var ring = panel(corner: diameter / 2, bezel: width, dark: false)
        ring.tint = GlassTint(red: 1, green: 1, blue: 1, strength: 0.05)
        ring.lens = GlassLens(
            profile: .ring(center: width * 0.5, width: width * 0.84), thickness: width * 1.08, indexOfRefraction: 1.42,
            maximumOffset: 9, allowsFold: false, dispersion: 0.12, dispersionTaps: .sixTap, softness: 1
        )
        ring.lighting = .enhanced(
            azimuth: azimuth, environment: .studioLight, finish: .prismatic(spread: 1.4, saturation: 0.42, phase: 0.06)
        )
        ring.lighting.fresnel = 0.85
        ring.lighting.specular = 0.75
        ring.lighting.reflection = 1
        ring.lighting.banding = 1
        ring.lighting.glints = 1
        ring.lighting.bandWidth = width
        ring.lighting.clean = clean
        ring.lighting.softRim = softRim
        return ring
    }
}

extension GlassParameters {
    /// CLEAN: the same panel with the triangular dither and, when it is lit by
    /// the refined look, the clean rim. Used by the lab pages that do not build
    /// their panels with ``RefinedLook`` (the glow gallery, the Apple vs
    /// GlassWeave rows), so their gradients (glow, halo, pooled light, shadows)
    /// are dithered like the rest.
    func cleaned() -> GlassParameters {
        var p = self
        p.dither = .triangular
        if p.lighting.look == .refined {
            p.lighting.clean = max(p.lighting.clean, RefinedLook.clean)
            p.lighting.softRim = RefinedLook.softRim
        }
        return p
    }
}
