import CoreGraphics

/// A color mixed into the glass.
///
/// The components are sRGB-encoded, in 0...1, like a UIKit color's red,
/// green, and blue in the sRGB color space. The renderer decodes them and
/// mixes in linear light.
public struct GlassTint: Hashable, Sendable {
    /// sRGB-encoded red, 0...1.
    public var red: Double
    /// sRGB-encoded green, 0...1.
    public var green: Double
    /// sRGB-encoded blue, 0...1.
    public var blue: Double
    /// How much of the tint replaces the refracted background, 0...1. Zero
    /// leaves the background unchanged; one shows only the tint color.
    public var strength: Double

    public init(red: Double, green: Double, blue: Double, strength: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.strength = strength
    }

    /// No tint.
    public static let none = GlassTint(red: 1, green: 1, blue: 1, strength: 0)
}

/// The optical settings of one rounded glass panel.
///
/// Units are explicit. Lengths are in **points** (the UI's unit); the
/// renderer converts them to pixels with the host's display scale.
/// Optical coefficients are **normalized** to 0...1.
///
/// | Property | Unit | Valid range | Meaning |
/// | --- | --- | --- | --- |
/// | ``cornerRadius`` | points | 0 to half the panel's shorter side | Outline corner radius. |
/// | ``bezelWidth`` | points | 0 to half the panel's shorter side | Width of the curved rim inside the outline. Refraction and edge illumination happen only there; the interior is flat and shows the background in place. |
/// | ``refraction`` | normalized | 0...1 | Rim displacement. At the outline the sample moves `refraction × bezelWidth / 2` toward the panel interior, falling off quadratically to zero at the rim's inner edge. Zero samples in place. |
/// | ``edgeHighlight`` | normalized | 0...1 | Edge illumination. One moves the outline at most ``maximumEdgeHighlight`` of the way to white on the side facing the upper-left light. |
/// | ``tint`` | normalized | components and strength 0...1 | See ``GlassTint``. |
/// | ``glow`` | see ``GlassGlow`` | see ``GlassGlow`` | A colored rim, inner glow, and center fill drawn over the glass, an optional halo outside it, and an optional pulse; ``GlassGlow/none`` (the default) draws nothing. |
/// | ``interior`` | see ``GlassInterior`` | see ``GlassInterior`` | An animated energy, rays, or embers pattern inside the outline, screened over the glass and the glow, fading toward the middle; ``GlassInterior/none`` (the default) draws nothing. |
///
/// **Normalization rule.** When a renderer accepts parameters, a non-finite
/// value (NaN or infinity) anywhere is rejected with
/// ``GlassParameterError/nonFinite(_:)``, because it has no nearest valid
/// value. A finite value outside its range is clamped to the nearest valid
/// value: negative lengths become zero, lengths longer than half the
/// panel's shorter side become that half, and coefficients and tint
/// components are clamped to 0...1. ``GlassGlow`` and ``GlassInterior``
/// document the same rule for their fields. The renderer reports the values it actually uses through
/// ``GlassRenderer/panel``.
public struct GlassParameters: Hashable, Sendable {
    /// Outline corner radius, in points.
    public var cornerRadius: Double
    /// Width of the curved rim inside the outline, in points.
    public var bezelWidth: Double
    /// Rim refraction strength, 0...1.
    public var refraction: Double
    /// Edge illumination strength, 0...1.
    public var edgeHighlight: Double
    /// Tint mixed into the glass.
    public var tint: GlassTint
    /// A colored glow at the edge, drawn over the glass; ``GlassGlow/none``
    /// for none.
    public var glow: GlassGlow
    /// An animated pattern inside the outline, drawn over the glass and the
    /// glow; ``GlassInterior/none`` for none.
    public var interior: GlassInterior

    /// The most edge illumination can brighten the outline: this fraction of
    /// the way from the glass color to white, at ``edgeHighlight`` 1.
    public static let maximumEdgeHighlight = 0.25

    public init(
        cornerRadius: Double = 28,
        bezelWidth: Double = 16,
        refraction: Double = 0.6,
        edgeHighlight: Double = 0.5,
        tint: GlassTint = .none,
        glow: GlassGlow = .none,
        interior: GlassInterior = .none
    ) {
        self.cornerRadius = cornerRadius
        self.bezelWidth = bezelWidth
        self.refraction = refraction
        self.edgeHighlight = edgeHighlight
        self.tint = tint
        self.glow = glow
        self.interior = interior
    }
}

/// One rounded glass panel on a surface.
public struct GlassPanel: Equatable, Sendable {
    /// The panel's rectangle in points, in the coordinate space of the
    /// surface it is drawn on: origin at the surface's top-left corner, x to
    /// the right, y downward. It may extend past the surface; only the part
    /// inside is drawn.
    ///
    /// A negative width or height is clamped to zero, and an empty panel
    /// draws nothing.
    public var frame: CGRect
    public var parameters: GlassParameters

    public init(frame: CGRect, parameters: GlassParameters = GlassParameters()) {
        self.frame = frame
        self.parameters = parameters
    }
}

/// Why a renderer refused glass parameters.
public enum GlassParameterError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The parameter that held the rejected value.
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case frame
        case cornerRadius
        case bezelWidth
        case refraction
        case edgeHighlight
        case tintRed
        case tintGreen
        case tintBlue
        case tintStrength
        /// A ``GlassGlow/ColorStop/red`` in ``GlassGlow/colors``.
        case glowColorRed
        /// A ``GlassGlow/ColorStop/green`` in ``GlassGlow/colors``.
        case glowColorGreen
        /// A ``GlassGlow/ColorStop/blue`` in ``GlassGlow/colors``.
        case glowColorBlue
        /// A ``GlassGlow/ColorStop/angle`` in ``GlassGlow/colors``.
        case glowColorAngle
        case glowRimWidth
        case glowRimSoftness
        case glowRimIntensity
        case glowInnerGlowRadius
        case glowInnerGlowIntensity
        case glowCenterOpacity
        case glowLightAngle
        case glowDirectionality
        case glowHaloRadius
        case glowHaloIntensity
        case glowPulsePeriod
        case glowPulseDepth
        /// A ``GlassInterior/Color/red`` in ``GlassInterior/colors``.
        case interiorColorRed
        /// A ``GlassInterior/Color/green`` in ``GlassInterior/colors``.
        case interiorColorGreen
        /// A ``GlassInterior/Color/blue`` in ``GlassInterior/colors``.
        case interiorColorBlue
        case interiorIntensity
        case interiorSpeed
        case interiorCenterFade
        /// The time passed to ``GlassRenderer/setEffectTime(_:)``.
        case effectTime
    }

    /// The value is NaN or infinite. Finite out-of-range values are clamped
    /// instead; a non-finite value has no nearest valid value.
    case nonFinite(Field)

    public var description: String {
        switch self {
        case .nonFinite(.effectTime):
            "The effectTime is NaN or infinite. Pass a finite number of seconds."
        case let .nonFinite(field):
            "The glass parameter \(field.rawValue) is NaN or infinite. Pass a finite value; finite values outside the documented range are clamped."
        }
    }
}

extension GlassParameters {
    /// Applies the normalization rule: rejects non-finite values and clamps
    /// finite ones into range. Lengths are capped at `maximumLength` (half
    /// the panel's shorter side).
    func normalized(maximumLength: Double) throws(GlassParameterError) -> GlassParameters {
        let checks: [(GlassParameterError.Field, Double)] = [
            (.cornerRadius, cornerRadius), (.bezelWidth, bezelWidth),
            (.refraction, refraction), (.edgeHighlight, edgeHighlight),
            (.tintRed, tint.red), (.tintGreen, tint.green), (.tintBlue, tint.blue),
            (.tintStrength, tint.strength),
        ]
        for (field, value) in checks where !value.isFinite {
            throw .nonFinite(field)
        }
        let glow = try glow.normalized(maximumLength: maximumLength)
        let interior = try interior.normalized()
        let length = { (value: Double) in min(max(value, 0), maximumLength) }
        let unit = { (value: Double) in min(max(value, 0), 1) }
        return GlassParameters(
            cornerRadius: length(cornerRadius),
            bezelWidth: length(bezelWidth),
            refraction: unit(refraction),
            edgeHighlight: unit(edgeHighlight),
            tint: GlassTint(
                red: unit(tint.red), green: unit(tint.green), blue: unit(tint.blue),
                strength: unit(tint.strength)
            ),
            glow: glow,
            interior: interior
        )
    }
}

extension GlassPanel {
    /// Applies the normalization rule to every panel of a list and keeps the
    /// first ``GlassRenderer/maximumPanelCount``. A non-finite value in any
    /// panel, kept or not, throws.
    package static func normalized(_ panels: [GlassPanel]) throws(GlassParameterError) -> [GlassPanel] {
        var normalized: [GlassPanel] = []
        normalized.reserveCapacity(min(panels.count, GlassRenderer.maximumPanelCount))
        for panel in panels {
            let checked = try panel.normalized()
            if normalized.count < GlassRenderer.maximumPanelCount {
                normalized.append(checked)
            }
        }
        return normalized
    }

    /// Applies the normalization rule to the frame and parameters.
    package func normalized() throws(GlassParameterError) -> GlassPanel {
        let values = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
        guard values.allSatisfy(\.isFinite) else { throw .nonFinite(.frame) }
        let width = max(Double(frame.size.width), 0)
        let height = max(Double(frame.size.height), 0)
        let frame = CGRect(x: frame.origin.x, y: frame.origin.y, width: width, height: height)
        let parameters = try parameters.normalized(maximumLength: min(width, height) / 2)
        return GlassPanel(frame: frame, parameters: parameters)
    }
}
