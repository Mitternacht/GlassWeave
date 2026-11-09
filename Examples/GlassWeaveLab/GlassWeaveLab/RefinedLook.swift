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
}
