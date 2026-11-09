import Foundation
internal import GlassWeaveShaderTypes

/// The depth cues of a glass panel on a light page (GW-25): a drop shadow, a
/// contact shadow, an inner shadow, and a colored caustic, all driven by the
/// key light's direction.
///
/// > Important: Experimental. This API may change before a stable release.
///
/// A screened glow or halo cannot show on white. Depth on a light page comes
/// from the opposite: the glass darkens what is around it and focuses a little
/// light. Native glass leaves that to the system; GlassWeave's own glass
/// draws it from here.
///
/// Grounding is off by default: ``none`` (the default of
/// ``GlassParameters/grounding``) draws nothing and the panel is drawn by a
/// pipeline variant that does not contain the grounding code, so its output is
/// byte for byte what GW-23 drew. A grounded panel adds a **pre-pass** before
/// every panel body, one blended quad per grounded panel, so a neighbour that
/// sits closer than the shadow is long is never erased by it: shadows multiply
/// onto what the page already shows, and a panel body leaves every pixel
/// outside its outline to the pre-pass.
///
/// | Part | What it is |
/// | --- | --- |
/// | ``drop`` | A soft shadow of the outline moved away from the light by ``Drop/offset``, with a Gaussian edge of ``Drop/blur`` points, grown by ``Drop/spread``. It multiplies the page. |
/// | ``contact`` | A tight, darker line right at the outline, ``Contact/width`` points deep (0 to 3), where the glass touches the page. It multiplies the page. |
/// | ``inner`` | A shadow just inside the outline on the side nearest the light, as an inset shadow moved away from the light. It multiplies the glass, under the highlights. |
/// | ``caustic`` | A band of colored light along the outline's far side, ``Caustic/offset`` points from it, whose red, green, and blue parts part by ``Caustic/dispersion`` and whose hue turns around it by ``Caustic/spectrum``. It is added to the page and to the glass. It never darkens a channel. |
///
/// The shadows are **outside the outline only**: the body of translucent glass
/// is not darkened by its own drop shadow (the inner shadow is the shadow
/// inside). The direction is **away from the key light**: with
/// ``GlassParameters/lighting`` on, the key light's azimuth and elevation (the
/// renderer's light offset included) set it; otherwise ``lightAzimuth`` and
/// ``lightElevation`` do, with the same offset. A lower light throws longer
/// shadows (the offsets scale by `tan 50° / tan elevation`, between 0.35 and
/// 3).
///
/// **Blending and color.** The pre-pass blends on the encoded `bgra8Unorm`
/// target, so the drop, contact, and caustic colors are sRGB-encoded and the
/// shadows are multiplications of encoded values (an approximation of a
/// multiply in linear light; the glass's own inner shadow works in linear
/// light). A shadow never raises a channel and a caustic never lowers one.
///
/// **Limits.** A body does not see other panels' shadows under it (its
/// interior shows the background through the glass), and a panel with a halo
/// (``GlassGlow/haloRadius``) draws the halo over its own shadow, replacing
/// other panels' shadows under the halo. Grounding is not merged between
/// panels.
///
/// **Normalization rule** (the ``GlassParameters`` rule). A NaN or infinite
/// value anywhere is rejected with ``GlassParameterError/nonFiniteGrounding(_:)``
/// naming its ``Field``; finite values out of range are clamped to the ranges
/// documented on each field.
public struct GlassGrounding: Hashable, Sendable {
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

        /// Black: a neutral shadow.
        public static let black = Color(red: 0, green: 0, blue: 0)
    }

    /// The soft shadow the panel throws on the page.
    public struct Drop: Hashable, Sendable {
        /// How far the shadow lies from the panel, away from the light, in
        /// points at the default 50 degree light, 0...``GlassGrounding/maximumOffset``.
        public var offset: Double
        /// The shadow's blur, in points: its edge is a Gaussian of half this
        /// standard deviation, 0...``GlassGrounding/maximumBlur``.
        public var blur: Double
        /// How far the shadow grows past the outline (negative shrinks it), in
        /// points, -32...32.
        public var spread: Double
        /// How dark the shadow is where it is deepest, 0...1.
        public var opacity: Double
        /// The color the page is multiplied toward: black for a neutral
        /// shadow, or a dark tint for a colored one.
        public var color: Color

        public init(offset: Double = 10, blur: Double = 18, spread: Double = -2, opacity: Double = 0.3, color: Color = .black) {
            self.offset = offset
            self.blur = blur
            self.spread = spread
            self.opacity = opacity
            self.color = color
        }
    }

    /// The tight shadow where the glass touches the page.
    public struct Contact: Hashable, Sendable {
        /// How far it reaches past the outline, in points, 0...3.
        public var width: Double
        /// How dark it is at the outline, 0...1.
        public var opacity: Double
        public var color: Color

        public init(width: Double = 2, opacity: Double = 0.3, color: Color = .black) {
            self.width = width
            self.opacity = opacity
            self.color = color
        }
    }

    /// The shadow inside the outline, on the side nearest the light.
    public struct Inner: Hashable, Sendable {
        /// How far it is moved away from the light, in points, 0 to half the
        /// panel's shorter side.
        public var offset: Double
        /// Its blur, in points, 0...``GlassGrounding/maximumBlur``.
        public var blur: Double
        /// How dark it is at the outline, 0...1.
        public var opacity: Double
        public var color: Color

        public init(offset: Double = 3, blur: Double = 8, opacity: Double = 0.25, color: Color = .black) {
            self.offset = offset
            self.blur = blur
            self.opacity = opacity
            self.color = color
        }

        /// No inner shadow.
        public static let off = Inner(opacity: 0)
    }

    /// The colored light the glass focuses on the page.
    public struct Caustic: Hashable, Sendable {
        /// How far the band's center lies from the outline, away from the
        /// light, in points, -32...64 (negative moves it inside).
        public var offset: Double
        /// The band's width, in points: it falls off as a Gaussian of this
        /// radius, 0...``GlassGrounding/maximumCausticRadius``.
        public var radius: Double
        /// How much light it adds at its brightest, 0...1.
        public var intensity: Double
        /// The light's color (sRGB-encoded). On white a caustic shows only
        /// where the page is darkened, so it is meant to sit in the shadow.
        public var color: Color
        /// How far the red, green, and blue parts of the band part, 0...1: the
        /// bright core stays white-ish and the edges fringe in color.
        public var dispersion: Double
        /// How far the hue turns around the band, 0...1: 0 keeps `color`, 1
        /// is a thin-film rainbow along it.
        public var spectrum: Double

        public init(
            offset: Double = 4, radius: Double = 7, intensity: Double = 0.6,
            color: Color = Color(red: 1, green: 0.92, blue: 0.8), dispersion: Double = 0.6, spectrum: Double = 0.6
        ) {
            self.offset = offset
            self.radius = radius
            self.intensity = intensity
            self.color = color
            self.dispersion = dispersion
            self.spectrum = spectrum
        }

        /// No caustic.
        public static let off = Caustic(intensity: 0)
    }

    /// The parameter that held a rejected value.
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case dropOffset, dropBlur, dropSpread, dropOpacity, dropRed, dropGreen, dropBlue
        case contactWidth, contactOpacity, contactRed, contactGreen, contactBlue
        case innerOffset, innerBlur, innerOpacity, innerRed, innerGreen, innerBlue
        case causticOffset, causticRadius, causticIntensity, causticRed, causticGreen, causticBlue
        case causticDispersion, causticSpectrum
        case lightAzimuth, lightElevation
    }

    /// Whether grounding draws. `false` is ``none``.
    public var isEnabled: Bool
    public var drop: Drop
    public var contact: Contact
    public var inner: Inner
    public var caustic: Caustic
    /// The light's azimuth in degrees (0 is the top, clockwise) when the
    /// panel's ``GlassParameters/lighting`` is off; with it on, its key light
    /// is used instead. Any finite value; reduced into 0 to 360.
    public var lightAzimuth: Double
    /// The light's elevation in degrees when ``GlassParameters/lighting`` is
    /// off, clamped to 0...90.
    public var lightElevation: Double

    /// The most a shadow or caustic is moved, in points.
    public static let maximumOffset = 64.0
    /// The most a shadow blurs, in points.
    public static let maximumBlur = 64.0
    /// The widest a caustic band is, in points.
    public static let maximumCausticRadius = 48.0
    /// The widest contact shadow, in points.
    public static let maximumContactWidth = 3.0

    public init(
        isEnabled: Bool = true,
        drop: Drop = Drop(),
        contact: Contact = Contact(),
        inner: Inner = .off,
        caustic: Caustic = .off,
        lightAzimuth: Double = 0,
        lightElevation: Double = 50
    ) {
        self.isEnabled = isEnabled
        self.drop = drop
        self.contact = contact
        self.inner = inner
        self.caustic = caustic
        self.lightAzimuth = lightAzimuth
        self.lightElevation = lightElevation
    }

    /// No grounding: the panel is drawn as it was before GW-25, byte for byte.
    public static let none = GlassGrounding(isEnabled: false)

    /// Whether grounding changes the picture. A panel without it is drawn by a
    /// pipeline variant that does not contain the grounding code.
    public var isActive: Bool {
        isEnabled && (drop.opacity > 0 || contact.opacity > 0 || inner.opacity > 0 || caustic.intensity > 0)
    }

    /// Applies the normalization rule. `maximumLength` is half the panel's
    /// shorter side.
    package func normalized(maximumLength: Double) throws(GlassParameterError) -> GlassGrounding {
        guard isEnabled else { return .none }
        let checks: [(Field, Double)] = [
            (.dropOffset, drop.offset), (.dropBlur, drop.blur), (.dropSpread, drop.spread), (.dropOpacity, drop.opacity),
            (.dropRed, drop.color.red), (.dropGreen, drop.color.green), (.dropBlue, drop.color.blue),
            (.contactWidth, contact.width), (.contactOpacity, contact.opacity),
            (.contactRed, contact.color.red), (.contactGreen, contact.color.green), (.contactBlue, contact.color.blue),
            (.innerOffset, inner.offset), (.innerBlur, inner.blur), (.innerOpacity, inner.opacity),
            (.innerRed, inner.color.red), (.innerGreen, inner.color.green), (.innerBlue, inner.color.blue),
            (.causticOffset, caustic.offset), (.causticRadius, caustic.radius), (.causticIntensity, caustic.intensity),
            (.causticRed, caustic.color.red), (.causticGreen, caustic.color.green), (.causticBlue, caustic.color.blue),
            (.causticDispersion, caustic.dispersion), (.causticSpectrum, caustic.spectrum),
            (.lightAzimuth, lightAzimuth), (.lightElevation, lightElevation),
        ]
        for (field, value) in checks where !value.isFinite {
            throw .nonFiniteGrounding(field)
        }
        let unit = { (value: Double) in min(max(value, 0), 1) }
        let range = { (value: Double, low: Double, high: Double) in min(max(value, low), high) }
        let color = { (color: Color) in Color(red: unit(color.red), green: unit(color.green), blue: unit(color.blue)) }
        var result = self
        result.drop = Drop(
            offset: range(drop.offset, 0, Self.maximumOffset), blur: range(drop.blur, 0, Self.maximumBlur),
            spread: range(drop.spread, -32, 32), opacity: unit(drop.opacity), color: color(drop.color)
        )
        result.contact = Contact(
            width: range(contact.width, 0, Self.maximumContactWidth), opacity: unit(contact.opacity), color: color(contact.color)
        )
        result.inner = Inner(
            offset: range(inner.offset, 0, maximumLength), blur: range(inner.blur, 0, Self.maximumBlur),
            opacity: unit(inner.opacity), color: color(inner.color)
        )
        result.caustic = Caustic(
            offset: range(caustic.offset, -32, Self.maximumOffset), radius: range(caustic.radius, 0, Self.maximumCausticRadius),
            intensity: unit(caustic.intensity), color: color(caustic.color),
            dispersion: unit(caustic.dispersion), spectrum: unit(caustic.spectrum)
        )
        result.lightAzimuth = GlassGlow.reducedAngle(lightAzimuth)
        result.lightElevation = range(lightElevation, 0, 90)
        return result
    }
}

extension GlassPanelGeometry {
    /// The grounding of one panel resolved to pixels and a direction (GW-25).
    /// The shader (`Glass.metal`, "Grounding") is the reference; there is no
    /// CPU mirror of the per-pixel model.
    struct Grounding: Equatable {
        var record: GWGroundingUniforms

        /// Resolves a normalized, active grounding, or returns `nil` for a
        /// panel drawn without it.
        init?(
            _ grounding: GlassGrounding, lighting: Lighting?, offset: GlassLightOffset, displayScale: Double
        ) {
            guard grounding.isActive else { return nil }
            // The light: the key light when there is one (its azimuth already
            // carries the offset; its elevation is the z of its direction).
            let azimuth: Double
            let elevation: Double
            if let lighting {
                azimuth = lighting.keyAzimuthDegrees
                elevation = asin(min(max(Double(lighting.record.key.z), 0), 1)) * 180 / .pi
            } else {
                azimuth = GlassGlow.reducedAngle(grounding.lightAzimuth + offset.azimuth)
                elevation = min(max(grounding.lightElevation + offset.elevation, 0), 90)
            }
            let radians = azimuth * .pi / 180
            // Away from the light: the light's direction is (sin, -cos), y down.
            let direction = SIMD2<Float>(Float(-sin(radians)), Float(cos(radians)))
            // A lower light throws a longer shadow, as tan 50 / tan elevation.
            let scale = min(max(tan(50.0 * .pi / 180) / tan(max(elevation, 5) * .pi / 180), 0.35), 3)
            let px = displayScale
            func encoded(_ color: GlassGrounding.Color, _ alpha: Double) -> SIMD4<Float> {
                SIMD4(Float(color.red), Float(color.green), Float(color.blue), Float(alpha))
            }
            func linear(_ color: GlassGrounding.Color, _ alpha: Double) -> SIMD4<Float> {
                SIMD4(
                    Float(GlassPanelGeometry.decodeSRGB(color.red)), Float(GlassPanelGeometry.decodeSRGB(color.green)),
                    Float(GlassPanelGeometry.decodeSRGB(color.blue)), Float(alpha)
                )
            }
            var record = GWGroundingUniforms()
            var flags = GWGroundingFlagActive.rawValue
            var reach = 0.0
            let drop = grounding.drop, contact = grounding.contact, inner = grounding.inner, caustic = grounding.caustic
            record.shadowDirection = direction
            if drop.opacity > 0 {
                record.dropColor = encoded(drop.color, drop.opacity)
                record.dropOffset = Float(drop.offset * scale * px)
                record.dropSigma = Float(max(drop.blur * 0.5 * px, 0.25))
                record.dropSpread = Float(drop.spread * px)
                flags |= GWGroundingFlagShadow.rawValue
                reach = max(reach, drop.offset * scale * px + max(drop.spread * px, 0) + 3 * Double(record.dropSigma))
            }
            if contact.opacity > 0, contact.width > 0 {
                record.contactColor = encoded(contact.color, contact.opacity)
                record.contactWidth = Float(contact.width * px)
                record.contactOffset = Float(0.3 * contact.width * px)
                flags |= GWGroundingFlagShadow.rawValue
                reach = max(reach, 1.3 * contact.width * px)
            }
            if inner.opacity > 0 {
                record.innerColor = linear(inner.color, inner.opacity)
                record.innerOffset = Float(inner.offset * scale * px)
                record.innerSigma = Float(max(inner.blur * 0.5 * px, 0.25))
                flags |= GWGroundingFlagInner.rawValue
            }
            if caustic.intensity > 0, caustic.radius > 0 {
                record.causticColor = encoded(caustic.color, caustic.intensity)
                record.causticOffset = Float(caustic.offset * scale * px)
                record.causticWidth = Float(caustic.radius * px)
                record.causticDispersion = Float(caustic.dispersion)
                record.causticSpectrum = Float(caustic.spectrum)
                flags |= GWGroundingFlagCaustic.rawValue
                reach = max(reach, abs(caustic.offset * scale * px) + caustic.radius * px * (3 + 1.2 * caustic.dispersion))
            }
            record.reach = Float(reach.rounded(.up) + 2)
            record.flags = flags
            self.record = record
        }

        /// The record of a panel without grounding: all zero.
        static let empty = GWGroundingUniforms()

        /// Whether the pre-pass draws a shadow quad.
        var drawsShadow: Bool { record.flags & GWGroundingFlagShadow.rawValue != 0 }
        /// Whether the pre-pass draws a caustic quad.
        var drawsCaustic: Bool { record.flags & GWGroundingFlagCaustic.rawValue != 0 }
        /// How far the pre-pass quad reaches past the panel rectangle, in pixels.
        var reach: Double { Double(record.reach) }

        static func == (lhs: Grounding, rhs: Grounding) -> Bool {
            withUnsafeBytes(of: lhs.record) { left in
                withUnsafeBytes(of: rhs.record) { right in left.elementsEqual(right) }
            }
        }
    }
}
