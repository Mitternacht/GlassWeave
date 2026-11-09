import CoreGraphics
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
        case thickness
        case saturation
        case brightness
        case scrimTextRed
        case scrimTextGreen
        case scrimTextBlue
        case scrimContrast
        case scrimRectX
        case scrimRectY
        case scrimRectWidth
        case scrimRectHeight
        case scrimFeather
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
/// **Experimental API** (GW-24a, GW-24b): the parameters, the pyramid that
/// filters the background, and the glass shader that samples it
/// (`docs/frost.md`). Set it as ``GlassParameters/frost``. The names and
/// ranges can change.
///
/// | Property | Unit | Valid range | Meaning |
/// | --- | --- | --- | --- |
/// | ``profile`` | | | Where the shape is blurred. |
/// | ``sigma`` | points | 0...``maximumSigma`` | The largest blur standard deviation. Zero is no frost. |
/// | ``transition`` | points | 0...``maximumTransition`` | For the two rim profiles, the distance over which the blur ramps between clear and frosted. |
/// | ``rampTop``, ``rampBottom`` | normalized | 0...1 | For the vertical ramp, the blur as a fraction of ``sigma`` at the shape's top and bottom edges. |
/// | ``grain`` | normalized | 0...1 | Static grain over the frosted part. |
/// | ``thickness`` | normalized | 0...1 | How much the blur follows the glass thickness of a lens (0 ignores it, 1 makes the blur proportional to the glass height there). |
/// | ``saturation``, ``brightness`` | factor | 0...2, 0.5...1.5 | The grade of the frosted color, applied in linear light (1 leaves it). |
/// | ``scrim`` | ``Legibility`` | | An optional guarantee of text contrast over a rectangle, from ``legibility(text:contrast:rect:feather:)``. |
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
    /// How much the blur follows the lens thickness, 0...1.
    public var thickness: Double
    /// The saturation of the frosted color, in linear light: 1 for none.
    public var saturation: Double
    /// The brightness of the frosted color, in linear light: 1 for none.
    public var brightness: Double
    /// The legibility scrim, or `nil` for none.
    public var scrim: Legibility?

    /// The largest ``sigma``, in points.
    public static let maximumSigma = 12.0
    /// The largest ``transition``, in points.
    public static let maximumTransition = 128.0

    public init(
        profile: Profile = .uniform, sigma: Double = 0, transition: Double = 24,
        rampTop: Double = 0, rampBottom: Double = 1, grain: Double = 0,
        thickness: Double = 0, saturation: Double = 1, brightness: Double = 1, scrim: Legibility? = nil
    ) {
        self.profile = profile
        self.sigma = sigma
        self.transition = transition
        self.rampTop = rampTop
        self.rampBottom = rampBottom
        self.grain = grain
        self.thickness = thickness
        self.saturation = saturation
        self.brightness = brightness
        self.scrim = scrim
    }

    /// The color of the text a scrim protects, sRGB-encoded, 0...1.
    public struct TextColor: Hashable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        public static let white = TextColor(red: 1, green: 1, blue: 1)
        public static let black = TextColor(red: 0, green: 0, blue: 0)

        /// The WCAG 2 relative luminance of the color (components clamped
        /// to 0...1).
        public var relativeLuminance: Double {
            GlassTint.relativeLuminance(red: red, green: green, blue: blue)
        }
    }

    /// A guarantee of text contrast over a rectangle of the glass (GW-24b).
    ///
    /// **Experimental.** After every light term and before the dither and the
    /// encode, the shader darkens (for light text) or lightens (for dark text)
    /// each pixel inside ``rect`` by the least that gives ``text`` the WCAG 2
    /// contrast ``contrast`` against it, aiming 3 % above it. A pixel that
    /// already has the ratio is untouched, so the glass keeps its character
    /// where it is quiet; hue is kept. ``feather`` points beyond the
    /// rectangle the scrim fades out, so there is no visible edge; pixels
    /// farther away are exactly as without it.
    public struct Legibility: Hashable, Sendable {
        /// The text color.
        public var text: TextColor
        /// The WCAG 2 contrast ratio to guarantee, 1...21.
        public var contrast: Double
        /// The area the text occupies, in points, in the same coordinate
        /// space as the panel's frame.
        public var rect: CGRect
        /// How far beyond ``rect`` the scrim fades out, in points, 0...64.
        public var feather: Double

        public init(text: TextColor, contrast: Double, rect: CGRect, feather: Double = 12) {
            self.text = text
            self.contrast = contrast
            self.rect = rect
            self.feather = feather
        }

        /// The largest feather, in points.
        public static let maximumFeather = 64.0
        /// The margin the shader aims for above ``contrast``.
        static let margin = 1.03
    }

    /// This frost with a legibility scrim: text of the color `text` placed
    /// over `rect` (points, in the panel's coordinate space) keeps at least
    /// `contrast` (WCAG 2, 1...21) against the glass, whatever is behind it
    /// and whatever light the panel draws. The scrim works without a blur
    /// (``sigma`` 0) too. Under Increase Contrast the policy raises it to
    /// 7:1 (``GlassAccessibilityPolicy``); under Reduce Transparency the
    /// frost and the scrim are removed (the surface is opaque).
    public func legibility(text: TextColor, contrast: Double, rect: CGRect, feather: Double = 12) -> GlassFrost {
        var frost = self
        frost.scrim = Legibility(text: text, contrast: contrast, rect: rect, feather: feather)
        return frost
    }

    /// No frost: nothing is built, and the glass draws as it did before.
    public static let none = GlassFrost()

    /// Whether this frost blurs nothing: no ``sigma``, or a vertical ramp
    /// that is zero at both edges. Meaningful on a normalized value. A frost
    /// that blurs nothing builds no pyramid, but its ``scrim`` still draws.
    public var isNone: Bool {
        sigma <= 0 || (profile == .verticalRamp && max(rampTop, rampBottom) <= 0)
    }

    /// Whether this frost changes any pixel: it blurs, or it has a scrim.
    /// Meaningful on a normalized value.
    public var isActive: Bool {
        !isNone || scrim != nil
    }

    /// This frost with every field in range, or an error for a non-finite
    /// field. See the normalization rule above.
    public func normalized() throws(GlassFrostError) -> GlassFrost {
        func finite(_ value: Double, _ field: GlassFrostError.Field, _ range: ClosedRange<Double>) throws(GlassFrostError) -> Double {
            guard value.isFinite else { throw .nonFinite(field) }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        let normalizedScrim: Legibility?
        if let scrim {
            let rect = scrim.rect
            normalizedScrim = Legibility(
                text: TextColor(
                    red: try finite(scrim.text.red, .scrimTextRed, 0...1),
                    green: try finite(scrim.text.green, .scrimTextGreen, 0...1),
                    blue: try finite(scrim.text.blue, .scrimTextBlue, 0...1)
                ),
                contrast: try finite(scrim.contrast, .scrimContrast, 1...21),
                rect: CGRect(
                    x: try finite(Double(rect.origin.x), .scrimRectX, -1e6...1e6),
                    y: try finite(Double(rect.origin.y), .scrimRectY, -1e6...1e6),
                    width: try finite(Double(rect.size.width), .scrimRectWidth, 0...1e6),
                    height: try finite(Double(rect.size.height), .scrimRectHeight, 0...1e6)
                ),
                feather: try finite(scrim.feather, .scrimFeather, 0...Legibility.maximumFeather)
            )
        } else {
            normalizedScrim = nil
        }
        return GlassFrost(
            profile: profile,
            sigma: try finite(sigma, .sigma, 0...Self.maximumSigma),
            transition: try finite(transition, .transition, 0...Self.maximumTransition),
            rampTop: try finite(rampTop, .rampTop, 0...1),
            rampBottom: try finite(rampBottom, .rampBottom, 0...1),
            grain: try finite(grain, .grain, 0...1),
            thickness: try finite(thickness, .thickness, 0...1),
            saturation: try finite(saturation, .saturation, 0...2),
            brightness: try finite(brightness, .brightness, 0.5...1.5),
            scrim: normalizedScrim
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

    /// The record the glass shader reads for one frosted panel (GW-24b), in
    /// destination pixels. `self` must be normalized. With a `layout` the
    /// blur samples that pyramid; without one (no pyramid was built, or the
    /// frost blurs nothing) only the scrim, if any, draws.
    func panelUniforms(
        panelCenter: SIMD2<Float>, panelHalfSize: SIMD2<Float>, cornerRadius: Float,
        displayScale: Double, layout: GWFrostPyramidLayout?
    ) -> GWFrostPanelUniforms {
        let sampling = layout != nil && !isNone
        let pyramid = layout ?? GWFrostPyramidLayout(regionOrigin: .zero, coverSize: SIMD2(1, 1), levelCount: 1, padding0: 0)
        var profile = uniforms(
            panelCenter: panelCenter, panelHalfSize: panelHalfSize, cornerRadius: cornerRadius,
            displayScale: displayScale, layout: pyramid
        )
        if !sampling { profile.sigma = 0 }
        var flags: UInt32 = sampling ? GWFrostFlagSampling.rawValue : 0
        var ratio: Float = 1
        var luminance: Float = 0
        var feather: Float = 0
        var center = SIMD2<Float>.zero
        var half = SIMD2<Float>.zero
        if let scrim {
            flags |= GWFrostFlagScrim.rawValue
            ratio = Float(scrim.contrast * Legibility.margin)
            luminance = Float(scrim.text.relativeLuminance)
            feather = Float(scrim.feather * displayScale)
            center = SIMD2(Float(scrim.rect.midX * displayScale), Float(scrim.rect.midY * displayScale))
            half = SIMD2(Float(scrim.rect.width * displayScale / 2), Float(scrim.rect.height * displayScale / 2))
        }
        return GWFrostPanelUniforms(
            profile: profile, thickness: Float(thickness), saturation: Float(saturation), brightness: Float(brightness),
            scrimRatio: ratio, scrimTextLuminance: luminance, scrimFeather: feather,
            scrimCenter: center, scrimHalfSize: half,
            flags: flags, padding0: 0, padding1: 0, padding2: 0
        )
    }
}
