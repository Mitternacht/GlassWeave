import Foundation
internal import GlassWeaveShaderTypes

/// The light model of a glass panel (GW-23): one movable light that gives the
/// glass a Fresnel outline, a specular streak along its upper inner edge,
/// reflections of an analytic photo studio on the rim, a chrome or prismatic
/// finish, and a soft bloom around the brightest lines.
///
/// > Important: Experimental. This API may change before a stable release.
///
/// Apple's native glass has no public control over its light. GlassWeave's own
/// glass takes its light from here: a **key light** (an azimuth and an
/// elevation, a color, an intensity, and a size) and an optional **rim
/// light**. The panel's surface is the height field it already has (the
/// ``GlassLens`` profile, or a quarter-round edge as wide as
/// ``GlassParameters/bezelWidth`` when there is no lens), so the light needs
/// no extra geometry: at every pixel the surface normal `N` follows from the
/// slope of that field.
///
/// The light model is off by default: ``legacy`` (the default of
/// ``GlassParameters/lighting``) draws the original edge highlight, byte for
/// byte, with the pipeline variant that does not contain the light model.
/// With any other value the original highlight turns to follow the key
/// light, and so does the glow's light angle unless ``drivesGlow`` is
/// `false`: there is one light, not two.
///
/// | Property | Unit | Valid range | Default | Meaning |
/// | --- | --- | --- | --- | --- |
/// | ``isEnabled`` | `Bool` | — | `true` (``legacy`` is `false`) | Whether the light model draws. |
/// | ``look`` | ``Look`` | — | ``Look/classic`` | `.classic` is the GW-23 model, byte for byte. `.refined` is the Apple-grade look: a thin crisp rim line and one soft, long highlight, both brighter on the lit side, with a calm edge reflection and no studio strips. |
/// | ``key`` | ``Light`` | see ``Light`` | top, 50°, white | The key light. Its azimuth also turns the studio. |
/// | ``rim`` | ``Light``? | see ``Light`` | `nil` | A second light that adds a specular streak of its own (it does not turn the studio). |
/// | ``environment`` | ``Environment`` | — | ``Environment/studioLight`` | The studio the rim reflects. |
/// | ``finish`` | ``Finish`` | — | ``Finish/dielectric`` | Glass, polished chrome, or chrome with a thin-film rainbow. |
/// | ``indexOfRefraction`` | ratio | 1 to 2.4 | 1.5 | Sets the reflectance at normal incidence, `F0 = ((n − 1) / (n + 1))²`. |
/// | ``fresnel`` | normalized | 0...1 | 0.6 | The bright outline where the surface turns edge-on. |
/// | ``specular`` | normalized | 0...1 | 0.8 | The streak of the key (and rim) light. |
/// | ``reflection`` | normalized | 0...1 | 0.8 | How much of the studio the rim reflects. |
/// | ``bloom`` | normalized | 0...1 | 0 | A soft glow around the brightest lines, spread along the surface. |
/// | ``bloomWidth`` | points | 0 to ``maximumBloomWidth`` | 6 | The most the bloom reaches. Exactly zero beyond it. |
/// | ``bandWidth`` | points | 0 to half the shorter side | `nil` | How deep into the glass the light terms reach. `nil` is the surface's own bevel. |
/// | ``crispOutline`` | `Bool` | — | `false` | Draws the Fresnel outline as a hairline that contrasts with the glass under it (light on dark, dark on light) instead of adding light, so it also shows on a white or opaque surface. The accessibility policy turns it on. |
/// | ``drivesGlow`` | `Bool` | — | `true` | Whether the glow's ``GlassGlow/lightAngle`` follows the key light. |
/// | ``edgeDepth`` | normalized | 0...1 | 0 | The refined look's thick-slab shading across the bevel: deeper (darker) toward the side away from the light, a faint inner light on the lit side. 0 draws none. Ignored by ``Look/classic``. |
/// | ``banding`` | normalized | 0...1 | 0 | The polished finishes' reflection bands across the bevel (``Finish/chrome(tint:)``, ``Finish/prismatic(spread:saturation:phase:)``): alternating bright and dark stripes, as in a polished metal ring. 0 draws none. |
/// | ``glints`` | normalized | 0...1 | 0 | Small bright glints at fixed angles around a polished rim (one facing the light, a weaker opposite, two faint at the sides), colored by the thin film with the prismatic finish. 0 draws none. |
/// | ``presence`` | normalized | 0...1 | 0 | The refined look's liveliness without any extra bend: the body picks up the colors behind it softly (a few wide samples of the backdrop), lifts a little in luminance, and the inner edge carries a soft glow that follows the backdrop's color, brighter on the lit side, with a deeper far side. 0 draws none. Ignored by ``Look/classic``. Experimental. |
/// | ``clean`` | normalized | 0...1 | 0 | The refined look's clean rim (CLEAN, experimental): every term that draws the rim and the edge (the hairline, the soft highlight, the inner glow and the thick-slab shade) falls off smoothly from the outline inward, in one gradient with no ring, crease or doubled line; the polished finishes' bands become wide and soft and the glints broader and calmer; the contrasting hairline changes polarity smoothly; the frost grain gives way to a static triangular dither of one 8-bit step. It adds no edge detail and raises no bend. 0 draws the look as before, byte for byte. Ignored by ``Look/classic``. |
/// | ``softRim`` | normalized | 0...1 | 0 | With ``clean`` above 0 (CLEAN-2, experimental): how much of the wide, soft rim the clean look keeps. 0, the default, is a thin crisp hairline about 0.7 points wide, like the system glass's rim, with one gentle light and shade variation around the outline; 1 is the first clean pass's soft gradient of about ten points (the soft highlight, the Fresnel body, the inner glow and shade and the slab shade at their wide reach), kept as an explicit opt-in for the glow look; values between mix the two. Ignored when ``clean`` is 0 and by ``Look/classic``. |
///
/// **The model** (`docs/glass-optics.md`). With the viewer's direction
/// `V = (0, 0, 1)` and the light's `L`, the reflected fraction is Schlick's
/// `F = F0 + (1 − F0)(1 − N·V)⁵`. The reflection direction `R = reflect(−V, N)`
/// indexes an analytic studio (a sky, a horizon line, a floor, and three
/// softboxes: a wide key box above and two tall strips at either side, all
/// turning with the key light's azimuth). The specular streak is a
/// Blinn-Phong lobe `(N·H)ᵖ` whose exponent is limited so the lobe is never
/// narrower than the surface's change of normal across one pixel. Everything
/// the light adds passes a soft knee (identity below 0.8, a smooth shoulder
/// above) so it never exceeds white or darkens a channel. Chrome and the
/// prismatic finish replace the glass by the studio's reflection on the rim
/// (source-over); the prismatic finish multiplies the softboxes' reflections
/// by a thin-film palette whose hue turns with the angle around the rim.
///
/// **Normalization rule** (the ``GlassParameters`` rule). A NaN or infinite
/// value anywhere is rejected with ``GlassParameterError/nonFiniteLighting(_:)``
/// naming its ``Field``. Finite values out of range are clamped to the ranges
/// above; azimuths and the prismatic phase are reduced into one turn.
public struct GlassLighting: Hashable, Sendable {
    /// An sRGB-encoded color, components 0...1.
    public struct Color: Hashable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// White.
        public static let white = Color(red: 1, green: 1, blue: 1)
    }

    /// One light.
    public struct Light: Hashable, Sendable {
        /// Where the light comes from around the panel, in degrees: 0 is the
        /// top, 90 the right, clockwise. Any finite value; it is reduced into
        /// 0 to 360.
        public var azimuth: Double
        /// How high the light stands above the glass plane, in degrees:
        /// 0 grazes the surface, 90 is straight toward the viewer. Clamped
        /// to 0...90.
        public var elevation: Double
        /// The light's color.
        public var color: Color
        /// Its strength, 0...1.
        public var intensity: Double
        /// 0 is a pinpoint (a thin, sharp streak); 1 a broad soft sheen.
        public var size: Double

        public init(
            azimuth: Double = 0, elevation: Double = 50, color: Color = .white, intensity: Double = 1, size: Double = 0.35
        ) {
            self.azimuth = azimuth
            self.elevation = elevation
            self.color = color
            self.intensity = intensity
            self.size = size
        }
    }

    /// The studio the panel's rim reflects.
    public enum Environment: Hashable, Sendable {
        /// A bright cyclorama: pale sky and floor, white softboxes. Looks
        /// right on light pages.
        case studioLight
        /// A dark room: near-black sky and floor with bright gray strips.
        /// Looks right on dark pages and over dark glass.
        case studioDark
    }

    /// How the rim reflects the studio.
    public enum Finish: Hashable, Sendable {
        /// Glass: the studio mixed in by Schlick's Fresnel term (faint on the
        /// face, strong toward the outline).
        case dielectric
        /// Polished metal on the rim: the studio, banded dark and bright as
        /// the surface turns, times the tint.
        case chrome(tint: Color)
        /// Chrome whose bright studio reflections carry a thin-film
        /// rainbow: the hue turns `spread` times around the rim (0...4),
        /// `saturation` 0...1, and `phase` (in turns, any finite value)
        /// shifts it.
        case prismatic(spread: Double, saturation: Double, phase: Double)

        /// Neutral chrome.
        public static let chrome = Finish.chrome(tint: .white)
    }

    /// How the model turns its parameters into light on the glass.
    ///
    /// > Important: Experimental. This API may change before a stable release.
    public enum Look: Hashable, Sendable, CaseIterable {
        /// The GW-23 model: a Fresnel outline, a Blinn-Phong lobe, and an
        /// analytic photo studio of softboxes reflected on the rim. Output is
        /// byte-identical to what GW-23 drew for the same values.
        case classic
        /// The Apple-grade look, restrained and from one light direction:
        /// - a thin, crisp **rim line** where the surface turns edge-on, bright
        ///   on the lit side, faint elsewhere, with a weak echo on the far side;
        /// - one soft, long **highlight** just inside the rim on the lit side
        ///   (never a round glare spot), placed by the key light's elevation and
        ///   widened by its ``Light/size``;
        /// - a calm **edge reflection**: a smooth sky-to-floor gradient mixed in
        ///   by a soft Fresnel term, lighter toward the light and darker away
        ///   from it, with no softboxes, no horizon ring and no gray wedges;
        /// - `.chrome` and `.prismatic` become a **polished glass edge**: one
        ///   soft reflective band across the bevel that stays partly clear, so
        ///   the backdrop still shows through, with the thin-film hue only on
        ///   that band and the rim line;
        /// - a **bloom** that is neutral and short.
        ///
        /// ``fresnel`` sets the rim line, ``specular`` the highlight,
        /// ``reflection`` the edge reflection, and ``bloom`` the glow around
        /// the lines. The optional ``rim`` light adds a second, weaker
        /// highlight. The studio ``environment`` chooses the gradient's colors.
        case refined
    }

    /// The parameter that held a rejected value.
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case keyAzimuth, keyElevation, keyRed, keyGreen, keyBlue, keyIntensity, keySize
        case rimAzimuth, rimElevation, rimRed, rimGreen, rimBlue, rimIntensity, rimSize
        case indexOfRefraction, fresnel, specular, reflection, bloom, bloomWidth, bandWidth
        case chromeTintRed, chromeTintGreen, chromeTintBlue
        case prismaticSpread, prismaticSaturation, prismaticPhase
        case edgeDepth, banding, glints, presence, clean, softRim
        /// The azimuth passed to ``GlassRenderer/setLightOffset(azimuth:elevation:)``.
        case lightOffsetAzimuth
        /// The elevation passed to ``GlassRenderer/setLightOffset(azimuth:elevation:)``.
        case lightOffsetElevation
    }

    /// Whether the light model draws. `false` is ``legacy``.
    public var isEnabled: Bool
    /// How the parameters become light: the GW-23 model or the Apple-grade
    /// look. Defaults to ``Look/classic`` so existing panels do not change.
    public var look: Look
    /// The key light.
    public var key: Light
    /// An optional second light; it adds a specular streak of its own.
    public var rim: Light?
    /// The studio the rim reflects.
    public var environment: Environment
    /// How the rim reflects the studio.
    public var finish: Finish
    /// Index of refraction, which sets the reflectance at normal incidence.
    public var indexOfRefraction: Double
    /// The Fresnel outline's strength, 0...1.
    public var fresnel: Double
    /// The specular streak's strength, 0...1.
    public var specular: Double
    /// The studio reflection's strength, 0...1.
    public var reflection: Double
    /// The bloom's strength, 0...1.
    public var bloom: Double
    /// The most the bloom reaches along the surface, in points.
    public var bloomWidth: Double
    /// How deep into the glass the light terms reach, in points; `nil` for
    /// the surface's own bevel.
    public var bandWidth: Double?
    /// Whether the glow's light angle follows the key light.
    public var drivesGlow: Bool
    /// Whether the Fresnel outline is a contrasting hairline.
    public var crispOutline: Bool
    /// The thick-slab shading of the bevel, 0...1 (the refined look only):
    /// the glass is deeper toward the side away from the light and carries a
    /// faint inner light on the lit side, so the edge reads as a slab. 0
    /// draws none. Reduce Transparency and Increase Contrast remove it.
    public var edgeDepth: Double
    /// The reflection bands of a polished rim, 0...1 (the refined look with a
    /// chrome or prismatic finish): alternating bright and dark stripes
    /// across the bevel. 0 draws none. Reduce Transparency and Increase
    /// Contrast remove it (they remove the finish).
    public var banding: Double
    /// Small glints around a polished rim, 0...1 (the refined look with a
    /// chrome or prismatic finish): at fixed angles from the key light, with
    /// the thin-film hue under the prismatic finish. 0 draws none.
    public var glints: Double
    /// The refined look's presence, 0...1 (experimental): a livelier body and
    /// edge that add no bend. The body picks up the backdrop's colors gently
    /// (a few wide samples of the backdrop around each pixel, never a lens
    /// offset), gains a slight luminance lift, and the inner edge carries a
    /// thin glow in the backdrop's own color, brighter on the lit side and
    /// deeper on the far side. A lens inlay gets a soft shade and its own rim
    /// light. 0 draws none, byte for byte. Reduce Transparency and Increase
    /// Contrast remove it.
    public var presence: Double
    /// The refined look's clean rim, 0...1 (experimental): the rim and the
    /// edge of a refined panel are drawn as one smooth gradient that falls off
    /// from the outline inward, like the rim of the system's glass, with no
    /// ring, crease or doubled line inside it. The soft highlight and the inner
    /// glow become monotone in depth, the thick-slab shade and the polished
    /// finishes' bands are widened and softened, the contrasting hairline
    /// changes polarity smoothly, and the panel is dithered with a static,
    /// isotropic triangular dither of one 8-bit step (also in its glow, halo
    /// and shadows) in place of the ordered dither and the frost grain. It adds
    /// no edge detail and changes no bend. 0 draws the look as before, byte for
    /// byte. It stays on under Reduce Transparency, Increase Contrast and Reduce
    /// Motion, because it only removes marks.
    public var clean: Double
    /// How much of the wide, soft rim the clean look keeps, 0...1
    /// (CLEAN-2, experimental). With ``clean`` above 0 the default rim is a
    /// thin crisp hairline (about 0.7 points wide) with one gentle light and
    /// shade variation around the outline, like the system glass's rim; the
    /// soft, wide gradient of the first clean pass (about ten points: the soft
    /// highlight, the Fresnel body, the inner glow and shade and the slab
    /// shade) is the opt-in at 1, and values between mix the two. The glow
    /// capabilities (``GlassGlow``, the inner light, the interior, the fill)
    /// are separate and unchanged. 0 is the default. Ignored when ``clean`` is
    /// 0 and by ``Look/classic``.
    public var softRim: Double

    /// The longest the bloom can reach: 24 points.
    public static let maximumBloomWidth = 24.0
    /// The highest index of refraction: 2.4.
    public static let maximumIndexOfRefraction = 2.4

    public init(
        isEnabled: Bool = true,
        key: Light = Light(),
        rim: Light? = nil,
        environment: Environment = .studioLight,
        finish: Finish = .dielectric,
        indexOfRefraction: Double = 1.5,
        fresnel: Double = 0.6,
        specular: Double = 0.8,
        reflection: Double = 0.8,
        bloom: Double = 0,
        bloomWidth: Double = 6,
        bandWidth: Double? = nil,
        drivesGlow: Bool = true,
        crispOutline: Bool = false,
        look: Look = .classic,
        edgeDepth: Double = 0,
        banding: Double = 0,
        glints: Double = 0,
        presence: Double = 0,
        clean: Double = 0,
        softRim: Double = 0
    ) {
        self.clean = clean
        self.softRim = softRim
        self.presence = presence
        self.edgeDepth = edgeDepth
        self.banding = banding
        self.glints = glints
        self.look = look
        self.isEnabled = isEnabled
        self.key = key
        self.rim = rim
        self.environment = environment
        self.finish = finish
        self.indexOfRefraction = indexOfRefraction
        self.fresnel = fresnel
        self.specular = specular
        self.reflection = reflection
        self.bloom = bloom
        self.bloomWidth = bloomWidth
        self.bandWidth = bandWidth
        self.drivesGlow = drivesGlow
        self.crispOutline = crispOutline
    }

    /// The original highlight: no light model. The panel's
    /// ``GlassParameters/edgeHighlight`` lights its outline from the upper
    /// left, exactly as before GW-23.
    public static let legacy = GlassLighting(isEnabled: false)

    /// The Apple-grade look (``Look/refined``) with its tuned starting values:
    /// a key light at 50 degrees, a thin rim line, a soft highlight, a calm
    /// edge reflection, and a short neutral bloom. Everything stays an
    /// ordinary stored property, so a host changes any of it afterwards.
    ///
    /// - Parameters:
    ///   - azimuth: The key light's azimuth in degrees (0 is the top,
    ///     clockwise); 315 is the upper left, where Apple's glass is lit from.
    ///   - environment: `.studioLight` on light pages, `.studioDark` on dark
    ///     ones.
    ///   - finish: `.dielectric` for glass, `.chrome` or `.prismatic` for a
    ///     polished edge.
    public static func refined(
        azimuth: Double = 315, environment: Environment = .studioLight, finish: Finish = .dielectric
    ) -> GlassLighting {
        GlassLighting(
            key: Light(azimuth: azimuth, elevation: 50, intensity: 1, size: 0.3),
            environment: environment, finish: finish,
            fresnel: 0.55, specular: 0.5, reflection: 0.4, bloom: 0.12, bloomWidth: 3,
            look: .refined
        )
    }

    /// The refined look with its enhancements (``edgeDepth``, and for the
    /// polished finishes ``banding`` and ``glints``): the same restrained
    /// light, a rim that reads as a thick slab, and, with `.chrome` or
    /// `.prismatic`, a polished band with reflection stripes and a few small
    /// glints. A little stronger than ``refined(azimuth:environment:finish:)``
    /// in its rim line and highlight; every value stays an ordinary stored
    /// property.
    ///
    /// > Important: Experimental. This API may change before a stable release.
    ///
    /// - Parameters: as ``refined(azimuth:environment:finish:)``.
    public static func enhanced(
        azimuth: Double = 315, environment: Environment = .studioLight, finish: Finish = .dielectric
    ) -> GlassLighting {
        var lighting = refined(azimuth: azimuth, environment: environment, finish: finish)
        lighting.fresnel = 0.7
        lighting.specular = 0.62
        lighting.edgeDepth = 0.6
        if case .dielectric = finish {} else {
            lighting.banding = 0.6
            lighting.glints = 0.6
        }
        return lighting
    }

    /// Whether the light model changes the picture. A panel without it is
    /// drawn by a pipeline variant that does not contain the light model.
    public var isActive: Bool {
        isEnabled
    }

    /// Applies the normalization rule. `maximumLength` is half the panel's
    /// shorter side.
    package func normalized(maximumLength: Double) throws(GlassParameterError) -> GlassLighting {
        guard isEnabled else { return .legacy }
        var checks: [(Field, Double)] = [
            (.keyAzimuth, key.azimuth), (.keyElevation, key.elevation), (.keyRed, key.color.red),
            (.keyGreen, key.color.green), (.keyBlue, key.color.blue), (.keyIntensity, key.intensity),
            (.keySize, key.size),
            (.indexOfRefraction, indexOfRefraction), (.fresnel, fresnel), (.specular, specular),
            (.reflection, reflection), (.bloom, bloom), (.bloomWidth, bloomWidth),
            (.edgeDepth, edgeDepth), (.banding, banding), (.glints, glints), (.presence, presence), (.clean, clean),
            (.softRim, softRim),
        ]
        if let rim {
            checks += [
                (.rimAzimuth, rim.azimuth), (.rimElevation, rim.elevation), (.rimRed, rim.color.red),
                (.rimGreen, rim.color.green), (.rimBlue, rim.color.blue), (.rimIntensity, rim.intensity),
                (.rimSize, rim.size),
            ]
        }
        if let bandWidth { checks.append((.bandWidth, bandWidth)) }
        switch finish {
        case .dielectric: break
        case let .chrome(tint):
            checks += [(.chromeTintRed, tint.red), (.chromeTintGreen, tint.green), (.chromeTintBlue, tint.blue)]
        case let .prismatic(spread, saturation, phase):
            checks += [(.prismaticSpread, spread), (.prismaticSaturation, saturation), (.prismaticPhase, phase)]
        }
        for (field, value) in checks where !value.isFinite {
            throw .nonFiniteLighting(field)
        }
        let unit = { (value: Double) in min(max(value, 0), 1) }
        let light = { (light: Light) in
            Light(
                azimuth: GlassGlow.reducedAngle(light.azimuth), elevation: min(max(light.elevation, 0), 90),
                color: Color(red: unit(light.color.red), green: unit(light.color.green), blue: unit(light.color.blue)),
                intensity: unit(light.intensity), size: unit(light.size)
            )
        }
        var result = self
        result.key = light(key)
        result.rim = rim.map(light)
        result.indexOfRefraction = min(max(indexOfRefraction, 1), Self.maximumIndexOfRefraction)
        result.fresnel = unit(fresnel)
        result.specular = unit(specular)
        result.reflection = unit(reflection)
        result.bloom = unit(bloom)
        result.edgeDepth = unit(edgeDepth)
        result.banding = unit(banding)
        result.glints = unit(glints)
        result.presence = unit(presence)
        result.clean = unit(clean)
        result.softRim = unit(softRim)
        result.bloomWidth = min(max(bloomWidth, 0), Self.maximumBloomWidth)
        result.bandWidth = bandWidth.map { min(max($0, 0), maximumLength) }
        switch finish {
        case .dielectric: break
        case let .chrome(tint):
            result.finish = .chrome(tint: Color(red: unit(tint.red), green: unit(tint.green), blue: unit(tint.blue)))
        case let .prismatic(spread, saturation, phase):
            let turns = phase - phase.rounded(.down)
            result.finish = .prismatic(spread: min(max(spread, 0), 4), saturation: unit(saturation), phase: turns + 0)
        }
        return result
    }
}

/// The offset a host adds to the key and rim lights' azimuths and elevations
/// each draw (``GlassRenderer/setLightOffset(azimuth:elevation:)``): tilt, a
/// dragged light, or an animated sweep.
struct GlassLightOffset: Equatable {
    var azimuth: Double = 0
    var elevation: Double = 0
}

extension GlassPanelGeometry {
    /// The light model of one panel resolved to pixels, linear light, and
    /// unit vectors (GW-23). The shader (`Glass.metal`, "Light model") is the
    /// reference; there is no CPU mirror of the per-pixel model.
    struct Lighting: Equatable {
        var record: GWLightingUniforms
        /// The key light's azimuth in degrees with the offset applied.
        var keyAzimuthDegrees: Double
        var drivesGlow: Bool

        /// Resolves a normalized, enabled lighting, or returns `nil` for the
        /// original highlight.
        init?(
            _ lighting: GlassLighting, offset: GlassLightOffset, displayScale: Double,
            bezelWidth: Double, cornerRadius: Double, halfSize: SIMD2<Double>, lens: Lens?
        ) {
            guard lighting.isActive else { return nil }
            let inscribed = min(halfSize.x, halfSize.y)
            // The surface: the lens's height field when it has one, else a
            // quarter-round edge as wide as the bezel.
            let hasHeight = lens.map { $0.profileCode != GWLensProfileRim.rawValue } ?? false
            let bevel = max(min(hasHeight ? lens?.bevel ?? bezelWidth : bezelWidth, inscribed), 0)
            let fieldRadius = hasHeight ? lens?.fieldRadius ?? 0 : min(max(cornerRadius, bevel), inscribed)
            let band = lighting.bandWidth.map { $0 * displayScale } ?? bevel
            let azimuth = GlassGlow.reducedAngle(lighting.key.azimuth + offset.azimuth)
            let elevation = min(max(lighting.key.elevation + offset.elevation, 0), 90)
            func direction(_ azimuth: Double, _ elevation: Double) -> SIMD3<Float> {
                let a = azimuth * .pi / 180, e = elevation * .pi / 180
                return SIMD3(Float(sin(a) * cos(e)), Float(-cos(a) * cos(e)), Float(sin(e)))
            }
            func color(_ color: GlassLighting.Color) -> SIMD3<Float> {
                SIMD3(Float(GlassPanelGeometry.decodeSRGB(color.red)), Float(GlassPanelGeometry.decodeSRGB(color.green)), Float(GlassPanelGeometry.decodeSRGB(color.blue)))
            }
            // Size 0 is a sharp lobe (exponent 400), size 1 a broad one (12).
            func exponent(_ size: Double) -> Float {
                Float(400 * pow(12.0 / 400.0, size))
            }
            let key = direction(azimuth, elevation)
            let keyColor = color(lighting.key.color)
            var rimDirection = SIMD3<Float>.zero, rimIntensity: Float = 0
            var rimColor = SIMD3<Float>.zero, rimExponent: Float = 0
            if let rim = lighting.rim, rim.intensity > 0 {
                rimDirection = direction(
                    GlassGlow.reducedAngle(rim.azimuth + offset.azimuth), min(max(rim.elevation + offset.elevation, 0), 90)
                )
                rimIntensity = Float(rim.intensity)
                rimColor = color(rim.color)
                rimExponent = exponent(rim.size)
            }
            var finish = GWLightingFinishDielectric.rawValue
            var tint = SIMD3<Float>(1, 1, 1)
            var prism = SIMD4<Float>.zero
            switch lighting.finish {
            case .dielectric: break
            case let .chrome(chromeTint):
                finish = GWLightingFinishChrome.rawValue
                tint = color(chromeTint)
            case let .prismatic(spread, saturation, phase):
                finish = GWLightingFinishPrismatic.rawValue
                prism = SIMD4(Float(spread), Float(saturation), Float(phase), 0)
            }
            let ior = lighting.indexOfRefraction
            let f0 = pow((ior - 1) / (ior + 1), 2)
            let azimuthRadians = azimuth * .pi / 180
            var record = GWLightingUniforms()
            record.key = SIMD4(key, Float(lighting.key.intensity))
            record.keyColor = SIMD4(keyColor, exponent(lighting.key.size))
            record.rim = SIMD4(rimDirection, rimIntensity)
            record.rimColor = SIMD4(rimColor, rimExponent)
            // The look rides in `tint.w`: 0 classic, 1 refined. The presence
            // adds its 8-bit level to the refined 1 (an exactly representable
            // integer), so a refined panel without it keeps the value 1.
            let presenceLevel: Float = lighting.look == .refined
                ? Float((min(max(lighting.presence, 0), 1) * 255).rounded()) : 0
            // CLEAN adds its own 8-bit level, 256 times, above the presence's.
            let cleanLevel: Float = lighting.look == .refined
                ? Float((min(max(lighting.clean, 0), 1) * 255).rounded()) : 0
            // CLEAN-2: the soft-rim level rides above the clean level (65536
            // times its 8-bit value; the sum stays an exactly representable
            // integer, at most 2^24), and only when the clean look is on.
            let softRimLevel: Float = lighting.look == .refined && cleanLevel > 0
                ? Float((min(max(lighting.softRim, 0), 1) * 255).rounded()) : 0
            record.tint = SIMD4(
                tint, lighting.look == .refined ? 1 + presenceLevel + 256 * cleanLevel + 65536 * softRimLevel : 0)
            // The refined look's enhancements ride in `prism.w`, which was zero
            // padding: three 8-bit fields (depth, banding, glints), exactly
            // representable in a float; zero when none is on.
            if lighting.look == .refined {
                func byte(_ value: Double) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
                let packed = byte(lighting.edgeDepth) | byte(lighting.banding) << 8 | byte(lighting.glints) << 16
                prism.w = Float(packed)
            }
            record.prism = prism
            record.finish = finish
            record.environment = lighting.environment == .studioDark
                ? GWLightingEnvironmentStudioDark.rawValue : GWLightingEnvironmentStudioLight.rawValue
            record.azimuth = Float(azimuthRadians)
            record.f0 = Float(f0)
            record.fresnel = Float(lighting.fresnel)
            record.specular = Float(lighting.specular)
            record.reflection = Float(lighting.reflection)
            record.bloom = Float(lighting.bloom)
            record.bloomWidth = Float(lighting.bloomWidth * displayScale)
            record.bevel = Float(bevel)
            record.fieldRadius = Float(fieldRadius)
            record.bandWidth = Float(band)
            // The normal turns by about a quarter turn over the bevel.
            record.footprint = Float(1.2 / max(bevel, 1))
            record.contrast = lighting.crispOutline ? 1 : 0
            record.edgeDirection = SIMD2(Float(sin(azimuthRadians)), Float(-cos(azimuthRadians)))
            self.record = record
            keyAzimuthDegrees = azimuth
            drivesGlow = lighting.drivesGlow
        }

        /// The record of a panel with the original highlight: all zero.
        static let empty = GWLightingUniforms()

        static func == (lhs: Lighting, rhs: Lighting) -> Bool {
            withUnsafeBytes(of: lhs.record) { left in
                withUnsafeBytes(of: rhs.record) { right in left.elementsEqual(right) }
            } && lhs.keyAzimuthDegrees == rhs.keyAzimuthDegrees && lhs.drivesGlow == rhs.drivesGlow
        }
    }
}
