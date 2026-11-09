/// A colored glow at a glass panel's edge that fades toward a see-through
/// middle.
///
/// The glow is one color layer drawn over the finished glass (refraction,
/// tint, and edge illumination): a bright **rim** band just inside the
/// outline, an **inner glow** that fades inward from the outline, and an
/// optional **center** fill. All three use the same color, which is either
/// one color or an angular gradient of up to four ``ColorStop``s around the
/// panel's center, and the rim and inner glow can be lit from one side.
/// With ``centerOpacity`` at 0 the middle of the panel stays exactly the
/// glass it would be without a glow.
///
/// Units are explicit. Lengths are in **points**, converted with the host's
/// display scale like the rest of the panel; coefficients are
/// **normalized**; angles are in **degrees**, 0 at the top of the panel and
/// increasing clockwise (90 right, 180 bottom, 270 left).
///
/// | Property | Unit | Valid range | Default | Meaning |
/// | --- | --- | --- | --- | --- |
/// | ``colors`` | ``ColorStop`` | 0 to ``maximumColorStops`` stops | none | One stop is a solid color; two to four form an angular gradient, interpolated in linear light around the center, wrapping from the last stop back to the first. No stops draws no glow. |
/// | ``rimWidth`` | points | 0 to half the panel's shorter side | 1.5 | Width of the solid rim band inside the outline. |
/// | ``rimSoftness`` | points | 0 to half the panel's shorter side | 1.5 | Width over which the rim's inner edge fades out, at least one pixel when drawn. With both rim lengths 0 there is no rim. |
/// | ``rimIntensity`` | normalized | 0...1 | 1 | Opacity of the rim. At 1, on a fully lit side, a rim pixel is exactly the glow color. |
/// | ``innerGlowRadius`` | points | 0 to half the panel's shorter side | 24 | How far inward the inner glow reaches. It is exactly zero beyond this depth. |
/// | ``innerGlowIntensity`` | normalized | 0...1 | 0.5 | Opacity of the inner glow at the outline, falling off as `(1 − depth / radius)²`. |
/// | ``centerOpacity`` | normalized | 0...1 | 0 | Opacity of the glow color everywhere inside, including the middle. At 0 the middle is see-through. |
/// | ``lightAngle`` | degrees | any finite value | 0 | The side the light comes from: 0 lights the top edge. |
/// | ``directionality`` | normalized | 0...1 | 0 | 0 lights the rim and inner glow evenly; 1 lights only the side facing the light. With facing `f = (1 + cos φ) / 2` for the angle `φ` between the edge's outward normal and the light, the light factor is `(1 − directionality) + directionality × f²`. |
///
/// **Normalization rule** (the ``GlassParameters`` rule): a NaN or infinite
/// value is rejected with ``GlassParameterError/nonFinite(_:)`` naming its
/// field. Finite values out of range are clamped: lengths to 0 through half
/// the panel's shorter side, coefficients and color components to 0...1.
/// Angles are reduced modulo 360 into `0..<360`. Only the first
/// ``maximumColorStops`` stops are kept, and they are then ordered by angle
/// (stably, so two stops at one angle make a hard edge). A glow without
/// stops becomes ``none``. ``GlassRenderer/panel`` reports the glow drawn.
public struct GlassGlow: Hashable, Sendable {
    /// One color of the glow and where it sits around the panel's center.
    public struct ColorStop: Hashable, Sendable {
        /// sRGB-encoded red, 0...1.
        public var red: Double
        /// sRGB-encoded green, 0...1.
        public var green: Double
        /// sRGB-encoded blue, 0...1.
        public var blue: Double
        /// Degrees around the center: 0 at the top, increasing clockwise.
        /// Any finite value; reduced modulo 360. Ignored for a single stop.
        public var angle: Double

        public init(red: Double, green: Double, blue: Double, angle: Double = 0) {
            self.red = red
            self.green = green
            self.blue = blue
            self.angle = angle
        }
    }

    /// The glow's colors: one for a solid glow, up to
    /// ``maximumColorStops`` for an angular gradient. Empty draws nothing.
    public var colors: [ColorStop]
    /// Width of the rim band inside the outline, in points.
    public var rimWidth: Double
    /// Width of the rim's soft inner edge, in points.
    public var rimSoftness: Double
    /// Opacity of the rim, 0...1.
    public var rimIntensity: Double
    /// How far inward the inner glow reaches, in points.
    public var innerGlowRadius: Double
    /// Opacity of the inner glow at the outline, 0...1.
    public var innerGlowIntensity: Double
    /// Opacity of the glow color in the whole interior, 0...1.
    public var centerOpacity: Double
    /// The side the light comes from, in degrees (0 = top, clockwise).
    public var lightAngle: Double
    /// How much the light favors the side it comes from, 0...1.
    public var directionality: Double

    /// The most color stops a glow uses.
    public static let maximumColorStops = 4

    /// No glow: no colors. The panel renders as it would without a glow.
    public static let none = GlassGlow(colors: [])

    public init(
        colors: [ColorStop],
        rimWidth: Double = 1.5,
        rimSoftness: Double = 1.5,
        rimIntensity: Double = 1,
        innerGlowRadius: Double = 24,
        innerGlowIntensity: Double = 0.5,
        centerOpacity: Double = 0,
        lightAngle: Double = 0,
        directionality: Double = 0
    ) {
        self.colors = colors
        self.rimWidth = rimWidth
        self.rimSoftness = rimSoftness
        self.rimIntensity = rimIntensity
        self.innerGlowRadius = innerGlowRadius
        self.innerGlowIntensity = innerGlowIntensity
        self.centerOpacity = centerOpacity
        self.lightAngle = lightAngle
        self.directionality = directionality
    }

    /// Whether the glow changes any pixel: it has a color and a rim, an
    /// inner glow, or a center fill.
    public var isVisible: Bool {
        guard !colors.isEmpty else { return false }
        let rim = rimIntensity > 0 && (rimWidth > 0 || rimSoftness > 0)
        let inner = innerGlowIntensity > 0 && innerGlowRadius > 0
        return rim || inner || centerOpacity > 0
    }
}

extension GlassGlow {
    /// Applies the normalization rule. Lengths are capped at `maximumLength`
    /// (half the panel's shorter side).
    func normalized(maximumLength: Double) throws(GlassParameterError) -> GlassGlow {
        for stop in colors {
            for (field, value) in [
                (GlassParameterError.Field.glowColorRed, stop.red),
                (.glowColorGreen, stop.green),
                (.glowColorBlue, stop.blue),
                (.glowColorAngle, stop.angle),
            ] where !value.isFinite {
                throw .nonFinite(field)
            }
        }
        let checks: [(GlassParameterError.Field, Double)] = [
            (.glowRimWidth, rimWidth), (.glowRimSoftness, rimSoftness),
            (.glowRimIntensity, rimIntensity), (.glowInnerGlowRadius, innerGlowRadius),
            (.glowInnerGlowIntensity, innerGlowIntensity), (.glowCenterOpacity, centerOpacity),
            (.glowLightAngle, lightAngle), (.glowDirectionality, directionality),
        ]
        for (field, value) in checks where !value.isFinite {
            throw .nonFinite(field)
        }
        guard !colors.isEmpty else { return .none }
        let length = { (value: Double) in min(max(value, 0), maximumLength) }
        let unit = { (value: Double) in min(max(value, 0), 1) }
        let stops = colors.prefix(Self.maximumColorStops).enumerated().map { index, stop in
            (index, ColorStop(
                red: unit(stop.red), green: unit(stop.green), blue: unit(stop.blue),
                angle: Self.reducedAngle(stop.angle)
            ))
        }
        // Stable order by angle: equal angles keep their given order.
        let ordered = stops.sorted { ($0.1.angle, $0.0) < ($1.1.angle, $1.0) }.map(\.1)
        return GlassGlow(
            colors: ordered,
            rimWidth: length(rimWidth),
            rimSoftness: length(rimSoftness),
            rimIntensity: unit(rimIntensity),
            innerGlowRadius: length(innerGlowRadius),
            innerGlowIntensity: unit(innerGlowIntensity),
            centerOpacity: unit(centerOpacity),
            lightAngle: Self.reducedAngle(lightAngle),
            directionality: unit(directionality)
        )
    }

    /// A finite angle in degrees reduced into `0..<360`.
    static func reducedAngle(_ degrees: Double) -> Double {
        let reduced = degrees.truncatingRemainder(dividingBy: 360)
        let positive = reduced < 0 ? reduced + 360 : reduced
        // -1e-20 + 360 rounds to 360; keep the range half-open.
        // Adding zero also turns -0 into 0.
        return positive >= 360 ? 0 : positive + 0
    }
}
