#if canImport(UIKit)
import GlassWeave
import simd
import UIKit

/// What the Core Animation layers of an ``EnhancedNativeGlassView`` draw for
/// one layout: paths, frames, shadow radii, and gradient colors, all in the
/// view's points. A pure function of the view's size, its glass's corner
/// radii, the display scale, and the presented glow, so tests can check it
/// directly.
///
/// Native mode draws two parts of a ``GlassGlow`` around Apple's glass,
/// never inside its material:
///
/// - **Rim:** a band just inside the outline, `rimWidth` deep, filled
///   crisply. With `rimSoftness` `s > 0` a shadow of `s / 4` of the band
///   extended by `s / 2` on both sides is added under it, and both are
///   clipped at the outline, so the rim is fully opaque to `rimWidth` and
///   its inner edge then fades over about `s` (half intensity at depth
///   `rimWidth + s / 2`, as in custom mode). With `s = 0` it is the crisp
///   band alone.
/// - **Halo:** outside the outline only (a mask removes it everywhere inside
///   the outline but its outermost pixel, so the glass never samples it
///   under its middle). It is a Core Animation shadow of the outline grown
///   by `haloOutsetFraction × haloRadius`, with a Gaussian of
///   `haloSigmaFraction × haloRadius`: about 95 % of `haloIntensity` at a
///   straight outline, 25 % at half the radius, and below 0.2 % at the
///   radius, a Gaussian stand-in for custom mode's `(1 − s / r)²`.
///
/// Both take their color and light from one angular function sampled every
/// two degrees into a conic `CAGradientLayer` (plus both sides of every
/// stop): the color is `GlowColorModel`'s linear-light gradient at the
/// pixel's angle (the panel scaled to a square, 0 at the top, clockwise:
/// the custom panel's convention), and the light uses the outward normal of
/// the outline point on that angle's ray, with the custom panel's light
/// formula and normal-field radius.
struct NativeGlowLayout {
    /// Per-corner radii in points, as the glass resolves them.
    struct CornerRadii: Equatable {
        var topLeft: CGFloat
        var topRight: CGFloat
        var bottomRight: CGFloat
        var bottomLeft: CGFloat

        static let zero = CornerRadii(topLeft: 0, topRight: 0, bottomRight: 0, bottomLeft: 0)

        /// Each radius limited to half the shorter side of `size`.
        func clamped(to size: CGSize) -> CornerRadii {
            let limit = max(min(size.width, size.height) / 2, 0)
            let clamp = { (value: CGFloat) in min(max(value.isFinite ? value : 0, 0), limit) }
            return CornerRadii(
                topLeft: clamp(topLeft), topRight: clamp(topRight),
                bottomRight: clamp(bottomRight), bottomLeft: clamp(bottomLeft)
            )
        }

        func offset(by delta: CGFloat) -> CornerRadii {
            CornerRadii(
                topLeft: max(topLeft + delta, 0), topRight: max(topRight + delta, 0),
                bottomRight: max(bottomRight + delta, 0), bottomLeft: max(bottomLeft + delta, 0)
            )
        }
    }

    /// A conic gradient: sRGB-encoded colors with alpha, at locations
    /// 0...1 around the gradient layer's center, starting at the top and
    /// running clockwise in the layer's unit square.
    struct Gradient: Equatable {
        /// Red, green, blue (sRGB-encoded), and alpha, each 0...1.
        var colors: [SIMD4<Double>]
        var locations: [Double]

        var cgColors: [CGColor] {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            return colors.map { color in
                CGColor(colorSpace: space, components: [color.x, color.y, color.z, color.w].map { CGFloat($0) })!
            }
        }
    }

    struct Rim {
        /// The outline of the glass: the rim is clipped to it.
        var clipPath: CGPath
        /// The band from the outline to `rimWidth`, filled crisply with the
        /// non-zero rule (empty for a rim of softness only).
        var bandPath: CGPath
        /// The band extended by half the softness on both sides, whose
        /// shadow softens the rim; the same as ``bandPath`` without softness.
        var softBandPath: CGPath
        /// The blur of the soft band (a shadow radius), 0 for a crisp band.
        var softnessRadius: CGFloat
        var gradient: Gradient
    }

    struct Halo {
        /// The halo's layers' frame in the view's points: the bounds grown
        /// by ``extent`` on every side.
        var frame: CGRect
        var extent: CGFloat
        /// In the halo frame's coordinates: the frame minus the outline
        /// shrunk by one pixel (non-zero rule), the mask that keeps the halo
        /// outside the glass.
        var holePath: CGPath
        /// In the halo frame's coordinates: the outline grown by the halo's
        /// outset, whose shadow is the halo.
        var shadowPath: CGPath
        var shadowRadius: CGFloat
        var gradient: Gradient
    }

    /// The halo's shadow source is the outline grown by this fraction of the
    /// halo radius ...
    static let haloOutsetFraction = 0.355
    /// ... blurred by a Gaussian with this fraction of the halo radius as
    /// its standard deviation (Core Animation's `shadowRadius`).
    static let haloSigmaFraction = 0.216
    /// The halo's layers reach this many standard deviations beyond the
    /// grown outline.
    static let haloSigmaReach = 4.0
    /// Gradient samples per turn (every two degrees).
    static let samplesPerTurn = 180

    let size: CGSize
    let radii: CornerRadii
    let displayScale: CGFloat
    let glow: GlassGlow
    let outline: CGPath
    let rim: Rim?
    let halo: Halo?

    /// - Parameters:
    ///   - glow: The presented glow (``EnhancedNativeGlassView/presentedGlow``):
    ///     normalized, with its rim lengths at most half the shorter side.
    init(size: CGSize, radii: CornerRadii, displayScale: CGFloat, glow: GlassGlow) {
        self.size = size
        let radii = radii.clamped(to: size)
        self.radii = radii
        let scale = displayScale.isFinite && displayScale > 0 ? displayScale : 1
        self.displayScale = scale
        self.glow = glow
        let bounds = CGRect(origin: .zero, size: size)
        outline = Self.roundedRect(bounds, radii: radii)
        guard size.width > 0, size.height > 0, glow.isVisible else {
            rim = nil
            halo = nil
            return
        }
        let pixel = 1 / scale
        let stops = GlowColorModel.linearStops(of: glow)
        let halfSize = SIMD2(Double(size.width), Double(size.height)) / 2
        // The light's normal field, as in custom mode: corners at least as
        // round as the rim's reach, so the light turns smoothly.
        let feather = max(glow.rimSoftness, Double(pixel))
        let normalRadii = radii.maximized(with: CGFloat(glow.rimWidth + feather)).clamped(to: size)
        let light = { (turn: Double) in
            Self.light(atTurn: turn, glow: glow, halfSize: halfSize, radii: radii, normalRadii: normalRadii)
        }

        let hasRim = glow.rimIntensity > 0 && (glow.rimWidth > 0 || glow.rimSoftness > 0)
        if hasRim {
            let width = CGFloat(glow.rimWidth), softness = CGFloat(glow.rimSoftness)
            let band = Self.band(in: bounds, radii: radii, from: 0, to: width)
            rim = Rim(
                clipPath: outline,
                bandPath: band,
                softBandPath: softness > 0 ? Self.band(in: bounds, radii: radii, from: -softness / 2, to: width + softness / 2) : band,
                softnessRadius: softness / 4,
                gradient: Self.gradient(stops: stops, intensity: glow.rimIntensity, light: light) { $0 }
            )
        } else {
            rim = nil
        }

        if glow.hasHalo {
            let radius = glow.haloRadius
            let outset = CGFloat(radius * Self.haloOutsetFraction)
            let sigma = CGFloat(radius * Self.haloSigmaFraction)
            let extent = (outset + sigma * CGFloat(Self.haloSigmaReach) + 1).rounded(.up)
            let frame = bounds.insetBy(dx: -extent, dy: -extent)
            let local = CGRect(origin: .zero, size: frame.size)
            let inner = CGRect(origin: CGPoint(x: extent, y: extent), size: size)
            let hole = CGMutablePath()
            hole.addRect(local)
            let holeRect = inner.insetBy(dx: pixel, dy: pixel)
            if holeRect.width > 0, holeRect.height > 0 {
                hole.addPath(Self.roundedRect(holeRect, radii: radii.offset(by: -pixel), clockwise: false))
            }
            // The halo layer is larger than the panel, so its unit square
            // measures angles differently; map each panel angle onto the
            // angle of the same ray in the halo layer's unit square.
            let grown = SIMD2(halfSize.x + Double(extent), halfSize.y + Double(extent))
            halo = Halo(
                frame: frame,
                extent: extent,
                holePath: hole,
                shadowPath: Self.roundedRect(inner.insetBy(dx: -outset, dy: -outset), radii: radii.offset(by: outset)),
                shadowRadius: sigma,
                gradient: Self.gradient(stops: stops, intensity: glow.haloIntensity, light: light) { turn in
                    Self.turn(ofDirection: Self.direction(atTurn: turn, halfSize: halfSize) / grown)
                }
            )
        } else {
            halo = nil
        }
    }

    // MARK: Color and light

    /// The light factor of the outline point on the ray at `turn`:
    /// `(1 − k) + k × ((1 + n·L) / 2)²` for directionality `k`.
    static func light(
        atTurn turn: Double, glow: GlassGlow, halfSize: SIMD2<Double>, radii: CornerRadii, normalRadii: CornerRadii
    ) -> Double {
        guard glow.directionality > 0 else { return 1 }
        let point = outlinePoint(atTurn: turn, halfSize: halfSize, radii: radii)
        let normal = outwardNormal(at: point, halfSize: halfSize, radii: normalRadii)
        let angle = glow.lightAngle * .pi / 180
        let toLight = SIMD2(Foundation.sin(angle), -Foundation.cos(angle))
        let facing = (1 + normal.x * toLight.x + normal.y * toLight.y) / 2
        return (1 - glow.directionality) + glow.directionality * facing * facing
    }

    /// The direction, in points (y down), of the ray at `turn` in the panel
    /// scaled to a square.
    static func direction(atTurn turn: Double, halfSize: SIMD2<Double>) -> SIMD2<Double> {
        let angle = turn * 2 * .pi
        return SIMD2(Foundation.sin(angle) * halfSize.x, -Foundation.cos(angle) * halfSize.y)
    }

    /// The angle in turns (0 at the top, clockwise, 0..<1) of a direction
    /// given in a unit square's coordinates.
    static func turn(ofDirection direction: SIMD2<Double>) -> Double {
        guard direction.x != 0 || direction.y != 0 else { return 0 }
        let turn = Foundation.atan2(direction.x, -direction.y) / (2 * .pi)
        return turn - turn.rounded(.down)
    }

    /// Where the ray from the center at `turn` crosses the outline, relative
    /// to the center, in points.
    static func outlinePoint(atTurn turn: Double, halfSize: SIMD2<Double>, radii: CornerRadii) -> SIMD2<Double> {
        let direction = direction(atTurn: turn, halfSize: halfSize)
        // The direction reaches the rectangle's edge at most at t = 1 and its
        // corner at t = √2; bisect the signed distance between 0 and 2.
        var low = 0.0, high = 2.0
        for _ in 0..<48 {
            let middle = (low + high) / 2
            if signedDistance(at: direction * middle, halfSize: halfSize, radii: radii) < 0 {
                low = middle
            } else {
                high = middle
            }
        }
        return direction * ((low + high) / 2)
    }

    /// The corner radius for the quadrant of `point` (relative to the
    /// center, y down).
    static func radius(at point: SIMD2<Double>, radii: CornerRadii) -> Double {
        let value: CGFloat = switch (point.x >= 0, point.y >= 0) {
        case (true, false): radii.topRight
        case (true, true): radii.bottomRight
        case (false, true): radii.bottomLeft
        case (false, false): radii.topLeft
        }
        return Double(value)
    }

    /// Signed distance to the rounded rectangle with per-corner radii:
    /// negative inside.
    static func signedDistance(at point: SIMD2<Double>, halfSize: SIMD2<Double>, radii: CornerRadii) -> Double {
        let radius = radius(at: point, radii: radii)
        let d = abs(point) - (halfSize - radius)
        let outside = SIMD2(max(d.x, 0), max(d.y, 0))
        return (outside.x * outside.x + outside.y * outside.y).squareRoot() + min(max(d.x, d.y), 0) - radius
    }

    /// The outward unit normal of the rounded rectangle with per-corner
    /// radii `radii` at `point` (relative to the center): radial in the
    /// corner regions, axis-aligned along the edges (custom mode's field).
    static func outwardNormal(at point: SIMD2<Double>, halfSize: SIMD2<Double>, radii: CornerRadii) -> SIMD2<Double> {
        let radius = radius(at: point, radii: radii)
        let d = abs(point) - (halfSize - radius)
        let sign = { (value: Double) -> Double in value > 0 ? 1 : (value < 0 ? -1 : 0) }
        if d.x > 0, d.y > 0 {
            let length = (d.x * d.x + d.y * d.y).squareRoot()
            return SIMD2(d.x / length * sign(point.x), d.y / length * sign(point.y))
        }
        return d.x > d.y ? SIMD2(sign(point.x), 0) : SIMD2(0, sign(point.y))
    }

    /// The conic gradient for one part of the glow: the glow color at every
    /// sampled panel angle, with alpha `intensity × light`, placed at the
    /// layer's own angle for that ray (`location`, identity for a layer the
    /// panel's size).
    static func gradient(
        stops: (colors: [SIMD3<Double>], turns: [Double]),
        intensity: Double,
        light: (Double) -> Double,
        location: (Double) -> Double
    ) -> Gradient {
        let count = samplesPerTurn
        // Both sides of every stop, so a hard edge (two stops at one angle)
        // stays hard; then a regular two-degree grid.
        var turns = (0...count).map { Double($0) / Double(count) }
        for stop in stops.turns {
            turns.append(stop)
            turns.append(max(stop - 1e-7, 0))
        }
        turns.sort()
        var colors: [SIMD4<Double>] = []
        var locations: [Double] = []
        for (index, turn) in turns.enumerated() {
            // The second of two equal turns takes the color after the stop;
            // the last sample closes the circle with the color just before
            // the top (equal to the first sample's unless a stop sits at 0).
            let sampled = index == turns.count - 1 ? 1 - 1e-9 : turn
            let linear = GlowColorModel.color(atTurn: sampled, colorsLinear: stops.colors, stopTurns: stops.turns)
            let alpha = min(max(intensity * light(sampled), 0), 1)
            colors.append(SIMD4(
                GlowColorModel.encodeSRGB(linear.x), GlowColorModel.encodeSRGB(linear.y),
                GlowColorModel.encodeSRGB(linear.z), alpha
            ))
            locations.append(turn >= 1 ? 1 : location(turn))
        }
        return Gradient(colors: colors, locations: locations)
    }

    // MARK: Paths

    /// The region between the depths `outer` and `inner` (points inside the
    /// outline; negative is outside), for the non-zero rule. Empty when the
    /// band has no width.
    static func band(in bounds: CGRect, radii: CornerRadii, from outer: CGFloat, to inner: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard inner > outer else { return path }
        path.addPath(roundedRect(bounds.insetBy(dx: outer, dy: outer), radii: radii.offset(by: -outer)))
        let innerRect = bounds.insetBy(dx: inner, dy: inner)
        if innerRect.width > 0, innerRect.height > 0 {
            path.addPath(roundedRect(innerRect, radii: radii.offset(by: -inner), clockwise: false))
        }
        return path
    }

    /// A rounded rectangle with per-corner circular corners, starting at the
    /// top edge, clockwise on screen (or counterclockwise, for a hole under
    /// the non-zero rule).
    static func roundedRect(_ rect: CGRect, radii: CornerRadii, clockwise: Bool = true) -> CGPath {
        let path = CGMutablePath()
        guard rect.width > 0, rect.height > 0 else { return path }
        let r = radii.clamped(to: rect.size)
        let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        if clockwise {
            path.move(to: CGPoint(x: minX + r.topLeft, y: minY))
            path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: maxY), radius: r.topRight)
            path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY), radius: r.bottomRight)
            path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: minY), radius: r.bottomLeft)
            path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: maxX, y: minY), radius: r.topLeft)
        } else {
            path.move(to: CGPoint(x: maxX - r.topRight, y: minY))
            path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX, y: maxY), radius: r.topLeft)
            path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: maxX, y: maxY), radius: r.bottomLeft)
            path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX, y: minY), radius: r.bottomRight)
            path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: minX, y: minY), radius: r.topRight)
        }
        path.closeSubpath()
        return path
    }
}

extension NativeGlowLayout.CornerRadii {
    /// Each radius at least `minimum`.
    func maximized(with minimum: CGFloat) -> Self {
        Self(
            topLeft: max(topLeft, minimum), topRight: max(topRight, minimum),
            bottomRight: max(bottomRight, minimum), bottomLeft: max(bottomLeft, minimum)
        )
    }
}
#endif
