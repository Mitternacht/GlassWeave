import Foundation

/// A colored glow at a glass panel's edge that fades toward a see-through
/// middle, with an optional halo outside the shape and a pulse.
///
/// The glow is one color layer drawn over the finished glass (refraction,
/// tint, and edge illumination): a bright **rim** band just inside the
/// outline, an **inner glow** that fades inward from the outline, and an
/// optional **center** fill. A **halo** can spill outside the outline over
/// the background. All of them use the same color, which is either one
/// color or an angular gradient of up to four ``ColorStop``s around the
/// panel's center, and the rim, inner glow, and halo can be lit from one
/// side. With ``centerOpacity`` at 0 the middle of the panel stays exactly
/// the glass it would be without a glow. A **pulse** scales the rim, inner
/// glow, and halo by ``pulseLevel(at:)`` at the renderer's effect time
/// (``GlassRenderer/effectTime``).
///
/// Units are explicit. Lengths are in **points**, converted with the host's
/// display scale like the rest of the panel; coefficients are
/// **normalized**; angles are in **degrees**, 0 at the top of the panel and
/// increasing clockwise (90 right, 180 bottom, 270 left); periods are in
/// **seconds** of effect time.
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
/// | ``directionality`` | normalized | 0...1 | 0 | 0 lights the rim, inner glow, and halo evenly; 1 lights only the side facing the light. With facing `f = (1 + cos φ) / 2` for the angle `φ` between the edge's outward normal and the light, the light factor is `(1 − directionality) + directionality × f²`. |
/// | ``haloRadius`` | points | 0 to ``maximumHaloRadius`` | 0 | How far the halo reaches outside the outline. It is exactly zero at and beyond this distance. 0 draws no halo. |
/// | ``haloIntensity`` | normalized | 0...1 | 0.5 | Opacity of the halo at the outline, falling off as `(1 − distance / haloRadius)²`. |
/// | ``pulsePeriod`` | seconds | ``minimumPulsePeriod`` to ``maximumPulsePeriod`` | 2 | The time of one pulse cycle. |
/// | ``pulseDepth`` | normalized | 0...1 | 0 | How far the pulse dims the rim, inner glow, and halo at its lowest point: their opacities are multiplied by ``pulseLevel(at:)``, which runs from 1 down to `1 − pulseDepth` and back. 0 is no pulse. |
///
/// **Halo.** Outside the outline, at distance `s` from it, the halo's opacity
/// is `a = haloIntensity × (1 − s / haloRadius)² × light`, with the light
/// factor of the rim (the same edge normals, continuous across the outline),
/// in the glow color `C` at the pixel's angle. The halo is light: its
/// premultiplied value `L = C × a` is screened over the background `B` in
/// linear light, `B + L × (1 − B)` per channel (the blend a designer's
/// "outer glow" uses). It never darkens any channel of the background,
/// never exceeds full intensity, shows no dark fringe, and over black is
/// exactly `L`; over white, like any light, it is invisible. The halo is
/// drawn only inside the surface: it is cut off where the surface ends, so
/// give a shape at least ``haloRadius`` of surface around it.
///
/// **Pulse.** At effect time `t`, the level is
/// `1 − pulseDepth × (1 − cos(2π t / pulsePeriod)) / 2`: 1 at `t = 0` and
/// every whole period, `1 − pulseDepth` half a period later. The center
/// fill does not pulse, so the middle stays as see-through as set. Its mean
/// over a period, `1 − pulseDepth / 2`, is the steady level used when motion
/// is reduced.
///
/// **Normalization rule** (the ``GlassParameters`` rule): a NaN or infinite
/// value is rejected with ``GlassParameterError/nonFinite(_:)`` naming its
/// field. Finite values out of range are clamped: lengths inside the shape
/// to 0 through half the panel's shorter side, the halo radius to 0 through
/// ``maximumHaloRadius``, the pulse period to ``minimumPulsePeriod`` through
/// ``maximumPulsePeriod``, and coefficients and color components to 0...1.
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
    /// How far the halo reaches outside the outline, in points; 0 for no
    /// halo.
    public var haloRadius: Double
    /// Opacity of the halo at the outline, 0...1.
    public var haloIntensity: Double
    /// The time of one pulse cycle, in seconds of effect time.
    public var pulsePeriod: Double
    /// How far the pulse dims the rim, inner glow, and halo, 0...1; 0 for no
    /// pulse.
    public var pulseDepth: Double

    /// The most color stops a glow uses.
    public static let maximumColorStops = 4

    /// The longest halo, in points.
    public static let maximumHaloRadius = 128.0

    /// The shortest pulse period, in seconds: at most two cycles a second,
    /// well below the three flashes a second that accessibility guidance
    /// (WCAG 2.3.1) treats as a seizure risk.
    public static let minimumPulsePeriod = 0.5

    /// The longest pulse period, in seconds.
    public static let maximumPulsePeriod = 60.0

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
        directionality: Double = 0,
        haloRadius: Double = 0,
        haloIntensity: Double = 0.5,
        pulsePeriod: Double = 2,
        pulseDepth: Double = 0
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
        self.haloRadius = haloRadius
        self.haloIntensity = haloIntensity
        self.pulsePeriod = pulsePeriod
        self.pulseDepth = pulseDepth
    }

    /// Whether the glow changes any pixel: it has a color and a rim, an
    /// inner glow, a center fill, or a halo.
    public var isVisible: Bool {
        guard !colors.isEmpty else { return false }
        return hasRim || hasInnerGlow || centerOpacity > 0 || hasHalo
    }

    /// Whether the glow draws a halo outside the outline.
    public var hasHalo: Bool {
        !colors.isEmpty && haloRadius > 0 && haloIntensity > 0
    }

    /// Whether the glow changes over time: it is visible, has a pulse, and
    /// the pulse has a rim, inner glow, or halo to modulate (the center fill
    /// does not pulse). A host draws new frames only while this is true.
    public var isAnimated: Bool {
        isVisible && pulseDepth > 0 && (hasRim || hasInnerGlow || hasHalo)
    }

    /// The factor the pulse applies to the rim, inner glow, and halo
    /// opacities at `seconds` of effect time:
    /// `1 − pulseDepth × (1 − cos(2π seconds / pulsePeriod)) / 2`.
    ///
    /// 1 at time 0 and every whole period, `1 − pulseDepth` half a period
    /// later; exactly 1 for a glow without a pulse. Evaluated for the
    /// values as given, so call it on a normalized glow (for example
    /// ``GlassRenderer/panel``) to get the level drawn. A non-finite time or
    /// a period that is not positive gives the level at time 0.
    public func pulseLevel(at seconds: Double) -> Double {
        guard pulseDepth > 0 else { return 1 }
        guard seconds.isFinite, pulsePeriod.isFinite, pulsePeriod > 0 else { return 1 }
        // The phase in whole turns, reduced in double precision first, so a
        // long-running clock keeps its accuracy.
        let turns = (seconds / pulsePeriod).truncatingRemainder(dividingBy: 1)
        return 1 - pulseDepth * (1 - Foundation.cos(2 * .pi * turns)) / 2
    }

    private var hasRim: Bool {
        rimIntensity > 0 && (rimWidth > 0 || rimSoftness > 0)
    }

    private var hasInnerGlow: Bool {
        innerGlowIntensity > 0 && innerGlowRadius > 0
    }
}

extension GlassGlow {
    /// Applies the normalization rule. Lengths are capped at `maximumLength`
    /// (half the panel's shorter side).
    package func normalized(maximumLength: Double) throws(GlassParameterError) -> GlassGlow {
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
            (.glowHaloRadius, haloRadius), (.glowHaloIntensity, haloIntensity),
            (.glowPulsePeriod, pulsePeriod), (.glowPulseDepth, pulseDepth),
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
            directionality: unit(directionality),
            haloRadius: min(max(haloRadius, 0), Self.maximumHaloRadius),
            haloIntensity: unit(haloIntensity),
            pulsePeriod: min(max(pulsePeriod, Self.minimumPulsePeriod), Self.maximumPulsePeriod),
            pulseDepth: unit(pulseDepth)
        )
    }

    /// The glow with its pulse replaced by the pulse's mean level: the rim,
    /// inner glow, and halo opacities are multiplied by
    /// `1 − pulseDepth / 2` and the depth becomes 0, so nothing animates.
    /// Used when motion is reduced.
    package func steadyAtMeanPulseLevel() -> GlassGlow {
        guard pulseDepth > 0 else { return self }
        let mean = 1 - pulseDepth / 2
        var steady = self
        steady.rimIntensity *= mean
        steady.innerGlowIntensity *= mean
        steady.haloIntensity *= mean
        steady.pulseDepth = 0
        return steady
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

/// The glow's color model on the CPU: the sRGB transfer function and the
/// angular gradient, interpolated in linear light. The custom panel's CPU
/// model (`GlassPanelGeometry`, mirrored by `Glass.metal`) and the
/// enhanced-native view in GlassWeaveUIKit both use it, so one `GlassGlow`
/// gives the same colors in both modes.
package enum GlowColorModel {
    /// The sRGB transfer function, encoded to linear light.
    package static func decodeSRGB(_ encoded: Double) -> Double {
        encoded <= 0.04045 ? encoded / 12.92 : Foundation.pow((encoded + 0.055) / 1.055, 2.4)
    }

    /// The sRGB transfer function, linear light (clamped to 0...1) to
    /// encoded.
    package static func encodeSRGB(_ linear: Double) -> Double {
        let c = min(max(linear, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * Foundation.pow(c, 1 / 2.4) - 0.055
    }

    /// A normalized glow's stop colors in linear light and their angles in
    /// turns (0 at the top, clockwise), in the glow's order (ascending angle).
    package static func linearStops(of glow: GlassGlow) -> (colors: [SIMD3<Double>], turns: [Double]) {
        (
            glow.colors.map { SIMD3(decodeSRGB($0.red), decodeSRGB($0.green), decodeSRGB($0.blue)) },
            glow.colors.map { $0.angle / 360 }
        )
    }

    /// The gradient color at an angle in turns, in linear light: linear
    /// interpolation between the neighbouring stops around the circle (the
    /// last stop blends back into the first). One stop is a solid color; no
    /// stops is black.
    package static func color(atTurn turn: Double, colorsLinear colors: [SIMD3<Double>], stopTurns turns: [Double]) -> SIMD3<Double> {
        guard colors.count > 1 else { return colors.first ?? .zero }
        // `following` stops lie at or before `turn`; the next one is after.
        let following = turns.lastIndex { $0 <= turn }.map { $0 + 1 } ?? 0
        let previous = (following + colors.count - 1) % colors.count
        let next = following % colors.count
        let start = following == 0 ? turns[previous] - 1 : turns[previous]
        let end = following == colors.count ? turns[next] + 1 : turns[next]
        let fraction = min(max((turn - start) / max(end - start, 1e-6), 0), 1)
        return colors[previous] + (colors[next] - colors[previous]) * fraction
    }
}
