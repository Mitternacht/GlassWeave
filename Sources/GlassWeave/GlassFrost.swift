import Foundation
internal import GlassWeaveShaderTypes

/// Why ``GlassFrost/normalized()`` refused a frost.
///
/// **Experimental API** (GW-24a). It mirrors ``GlassParameterError`` for the
/// frost fields; a later round may fold it into that type.
public enum GlassFrostError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The frost field that held the rejected value.
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case sigma
        case transition
        case rampTop
        case rampBottom
        case grain
    }

    /// A value was NaN or infinite, which has no nearest valid value.
    case nonFinite(Field)

    public var description: String {
        switch self {
        case let .nonFinite(field):
            "GlassFrost.\(field.rawValue) is not a finite number. Pass a finite value; a finite value outside the range is clamped, a NaN or infinity is rejected."
        }
    }
}

/// How blurred the glass is: a continuous, per-shape frost.
///
/// **Experimental API** (GW-24a): this round delivers the parameters and the
/// pyramid that filters the background (`docs/frost.md`); the glass shader
/// does not sample the pyramid yet, so no frost shows on screen until the
/// wiring lands. The names and ranges can change.
///
/// | Property | Unit | Valid range | Meaning |
/// | --- | --- | --- | --- |
/// | ``profile`` | | | Where the shape is blurred. |
/// | ``sigma`` | points | 0...``maximumSigma`` | The largest blur standard deviation. Zero is no frost. |
/// | ``transition`` | points | 0...``maximumTransition`` | For the two rim profiles, the distance over which the blur ramps between clear and frosted. |
/// | ``rampTop``, ``rampBottom`` | normalized | 0...1 | For the vertical ramp, the blur as a fraction of ``sigma`` at the shape's top and bottom edges. |
/// | ``grain`` | normalized | 0...1 | Static grain over the frosted part. |
///
/// **Default and off-by-default.** ``none`` (also `GlassFrost()`) builds no
/// pyramid and allocates nothing.
///
/// **Normalization rule.** As for ``GlassParameters``: ``normalized()``
/// rejects a non-finite value with ``GlassFrostError/nonFinite(_:)`` naming
/// the field, and clamps a finite value outside its range to the nearest
/// valid value.
///
/// The pyramid filters up to a blur of about 24 pixels (its coarsest level
/// is 1/32 resolution); a larger ``sigma`` saturates there.
public struct GlassFrost: Hashable, Sendable {
    /// Where a shape is blurred.
    public enum Profile: Int, Hashable, Sendable, CaseIterable {
        /// The same blur everywhere.
        case uniform = 0
        /// Frosted at the outline, clear toward the middle.
        case clearCenter = 1
        /// Clear at the outline, frosted toward the middle.
        case clearRim = 2
        /// A blur that ramps from the shape's top to its bottom.
        case verticalRamp = 3
    }

    public var profile: Profile
    /// The largest blur standard deviation, in points.
    public var sigma: Double
    /// The rim profiles' ramp distance, in points.
    public var transition: Double
    /// The vertical ramp's blur at the top edge, as a fraction of ``sigma``.
    public var rampTop: Double
    /// The vertical ramp's blur at the bottom edge, as a fraction of ``sigma``.
    public var rampBottom: Double
    /// Static grain, 0...1.
    public var grain: Double

    /// The largest ``sigma``, in points.
    public static let maximumSigma = 12.0
    /// The largest ``transition``, in points.
    public static let maximumTransition = 128.0

    public init(
        profile: Profile = .uniform, sigma: Double = 0, transition: Double = 24,
        rampTop: Double = 0, rampBottom: Double = 1, grain: Double = 0
    ) {
        self.profile = profile
        self.sigma = sigma
        self.transition = transition
        self.rampTop = rampTop
        self.rampBottom = rampBottom
        self.grain = grain
    }

    /// No frost: nothing is built, and the glass draws as it did before.
    public static let none = GlassFrost()

    /// Whether this frost blurs nothing: no ``sigma``, or a vertical ramp
    /// that is zero at both edges. Meaningful on a normalized value.
    public var isNone: Bool {
        sigma <= 0 || (profile == .verticalRamp && max(rampTop, rampBottom) <= 0)
    }

    /// This frost with every field in range, or an error for a non-finite
    /// field. See the normalization rule above.
    public func normalized() throws(GlassFrostError) -> GlassFrost {
        func finite(_ value: Double, _ field: GlassFrostError.Field, _ range: ClosedRange<Double>) throws(GlassFrostError) -> Double {
            guard value.isFinite else { throw .nonFinite(field) }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        return GlassFrost(
            profile: profile,
            sigma: try finite(sigma, .sigma, 0...Self.maximumSigma),
            transition: try finite(transition, .transition, 0...Self.maximumTransition),
            rampTop: try finite(rampTop, .rampTop, 0...1),
            rampBottom: try finite(rampBottom, .rampBottom, 0...1),
            grain: try finite(grain, .grain, 0...1)
        )
    }

    /// The record the shader reads for this frost on one rounded rectangle,
    /// in destination pixels. `self` must be normalized. The blur radius is
    /// limited to what a pyramid with `layout`'s levels can filter.
    func uniforms(
        panelCenter: SIMD2<Float>, panelHalfSize: SIMD2<Float>, cornerRadius: Float,
        displayScale: Double, layout: GWFrostPyramidLayout
    ) -> GWFrostProfileUniforms {
        let levels = Int(layout.levelCount)
        let limit = FrostPyramidGeometry.levelSigma(levels - 1)
        return GWFrostProfileUniforms(
            panelCenter: panelCenter, panelHalfSize: panelHalfSize,
            cornerRadius: cornerRadius,
            sigma: min(Float(sigma * displayScale), limit),
            transition: Float(max(transition * displayScale, 1)),
            rampTop: Float(rampTop), rampBottom: Float(rampBottom),
            grain: Float(grain),
            profile: UInt32(profile.rawValue), padding0: 0,
            layout: layout
        )
    }
}
