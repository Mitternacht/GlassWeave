import CoreGraphics
import Foundation

/// Text legibility over a tinted glass panel, whatever the background.
///
/// Inside the rim the panel shows `mix(background, tint, strength)` in linear
/// light (see ``GlassTint``). Relative luminance is linear in linear light,
/// so over a background of any luminance from black (0) to white (1) the
/// panel interior's luminance lies in
/// `strength × tintLuminance ... strength × tintLuminance + (1 − strength)`.
/// Text stays readable over every background only if its luminance lies
/// outside that span, far enough for the requested contrast ratio. These
/// functions compute that worst case with the WCAG 2 definitions of relative
/// luminance and contrast ratio, so an app can choose a tint that keeps its
/// native text readable over a moving source. Refraction moves samples but
/// cannot leave the 0...1 range, and edge illumination applies only in the
/// rim, so neither changes the interior bound.
///
/// **Inputs.** These functions follow the ``GlassParameters`` normalization
/// rule. Color components, the strength, and luminances outside 0...1 are
/// clamped to that range, as the renderer clamps a tint, so every answer
/// describes the panel that is actually drawn. A NaN or infinite input has no
/// nearest valid value: the renderer rejects such a tint with
/// ``GlassParameterError/nonFinite(_:)``, and these functions stop with a
/// precondition failure that names the input.
extension GlassTint {
    /// The WCAG 2 relative luminance of the tint color (its strength aside),
    /// after clamping the components to 0...1.
    public var relativeLuminance: Double {
        Self.relativeLuminance(red: red, green: green, blue: blue)
    }

    /// The WCAG 2 relative luminance of an sRGB-encoded color. Components
    /// outside 0...1 are clamped to it.
    public static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        0.2126 * GlassPanelGeometry.decodeSRGB(unitValue(red, "red"))
            + 0.7152 * GlassPanelGeometry.decodeSRGB(unitValue(green, "green"))
            + 0.0722 * GlassPanelGeometry.decodeSRGB(unitValue(blue, "blue"))
    }

    /// The WCAG 2 contrast ratio of two relative luminances, from 1 to 21.
    /// Luminances outside 0...1 are clamped to it.
    public static func contrastRatio(_ first: Double, _ second: Double) -> Double {
        let first = unitValue(first, "luminance")
        let second = unitValue(second, "luminance")
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// The lowest and highest luminance the panel interior can show over a
    /// background anywhere from black to white, for the strength clamped to
    /// 0...1.
    public var interiorLuminanceRange: ClosedRange<Double> {
        let strength = Self.unitValue(strength, "strength")
        let floor = strength * relativeLuminance
        // 1 − strength is never negative, so the bounds are ordered.
        return floor...(floor + (1 - strength))
    }

    /// The lowest contrast ratio between text of `textLuminance` and the
    /// panel interior, over every background from black to white. It is 1
    /// when some background makes the interior match the text.
    public func worstCaseContrast(againstTextLuminance textLuminance: Double) -> Double {
        let textLuminance = Self.unitValue(textLuminance, "text luminance")
        let range = interiorLuminanceRange
        if textLuminance <= range.lowerBound {
            return Self.contrastRatio(textLuminance, range.lowerBound)
        }
        if textLuminance >= range.upperBound {
            return Self.contrastRatio(textLuminance, range.upperBound)
        }
        return 1
    }

    /// The smallest strength, with this tint's color, for which
    /// ``worstCaseContrast(againstTextLuminance:)`` reaches `ratio`, or `nil`
    /// when no strength up to 1 can (for example, dark text on a dark tint).
    /// The current strength does not affect the answer.
    public func minimumStrength(forContrast ratio: Double, againstTextLuminance textLuminance: Double) -> Double? {
        precondition(ratio.isFinite, "GlassTint legibility: the contrast ratio is \(ratio); pass a finite ratio")
        let textLuminance = Self.unitValue(textLuminance, "text luminance")
        guard ratio > 1 else { return 0 }
        let tint = relativeLuminance
        var candidates: [Double] = []
        // Text darker than the darkest interior: s × Lt + 0.05 ≥ ratio × (Lt_text + 0.05).
        if tint > 0 {
            candidates.append((ratio * (textLuminance + 0.05) - 0.05) / tint)
        }
        // Text lighter than the brightest interior:
        // Lt_text + 0.05 ≥ ratio × (s × Lt + 1 − s + 0.05).
        if tint < 1 {
            candidates.append((1.05 - (textLuminance + 0.05) / ratio) / (1 - tint))
        }
        let feasible = candidates
            .map { max($0, 0) }
            .filter { $0 <= 1 }
            .filter { strength in
                var probe = self
                probe.strength = strength
                return probe.worstCaseContrast(againstTextLuminance: textLuminance) >= ratio * (1 - 1e-9)
            }
        return feasible.min()
    }

    /// One legibility input after the normalization rule: a finite value
    /// clamped to 0...1. A non-finite value stops execution with a message
    /// naming the input.
    private static func unitValue(_ value: Double, _ name: StaticString) -> Double {
        precondition(
            value.isFinite,
            "GlassTint legibility: the \(name) is \(value). Pass a finite value; the renderer rejects a non-finite tint with GlassParameterError.nonFinite, and finite values outside 0...1 are clamped."
        )
        return min(max(value, 0), 1)
    }
}

/// Legibility with inner light (GW-21, experimental).
///
/// Light is added to the glass, so it can lift the interior's luminance
/// above the tint's range. These bounds give the most it can do anywhere in
/// a rectangle of the panel, whatever the background, so an app can place
/// text where the light cannot reach, or choose a tint strength that still
/// gives the contrast it needs. Both are conservative: they ignore the
/// panel's rounded corners (which only reduce the light) and take each
/// emitter at its brightest color and full intensity.
extension GlassLight {
    /// The largest opacity any emitter's light has anywhere inside `rect`,
    /// 0...1, for a panel at `panelFrame` (both in the same coordinate
    /// space, in points) with the rim width `bezelWidth` in points.
    ///
    /// The body light is bounded by the center fade at the shallowest
    /// point of `rect` (its distance to the panel's nearest edge); the
    /// piping by its band, which only the part of `rect` within the piping
    /// width of the edge can reach. `rect` is clipped to the panel. Returns
    /// 0 for light that draws nothing, or for a `rect` outside the panel.
    public func maximumOpacity(in rect: CGRect, ofPanel panelFrame: CGRect, bezelWidth: Double) -> Double {
        guard isVisible else { return 0 }
        let area = rect.intersection(panelFrame)
        guard !area.isNull, area.width >= 0, area.height >= 0 else { return 0 }
        let shortSide = Double(min(panelFrame.width, panelFrame.height))
        guard shortSide > 0 else { return 0 }
        // The shallowest depth in `area`: its distance to the nearest edge.
        let depth = Double(min(
            area.minX - panelFrame.minX, panelFrame.maxX - area.maxX,
            area.minY - panelFrame.minY, panelFrame.maxY - area.maxY
        ))
        let w = min(max(depth / (shortSide / 2), 0), 1)
        let t = min(max((w - 0.3) / 0.55, 0), 1)
        let fade = 1 - min(max(centerFade, 0), 1) * t * t * (3 - 2 * t)
        let body = min(max(self.body, 0), 1) * fade
        let width = min(pipingWidth ?? bezelWidth, shortSide / 2)
        let band = width > 0 ? min(max(1 - depth / width, 0), 1) : 0
        let pipe = min(max(piping, 0), 1) * band * band
        let largest = emitters.filter { !$0.colors.isEmpty }.map { min(max($0.intensity, 0), 1) }.max() ?? 0
        return largest * (1 - (1 - body) * (1 - pipe))
    }

    /// The largest relative luminance (WCAG 2) any stop's color can have:
    /// its own, or with a hue drift the largest any rotation of its hue
    /// about the gray axis reaches, `mean + 0.478 × |chroma|` (Cauchy-
    /// Schwarz on the part of the color off the gray axis), at most 1. This
    /// is the most luminance one unit of light opacity can add.
    var brightestStopLuminance: Double {
        emitters.flatMap(\.colors).map { stop in
            let linear = SIMD3(
                GlassPanelGeometry.decodeSRGB(min(max(stop.red, 0), 1)),
                GlassPanelGeometry.decodeSRGB(min(max(stop.green, 0), 1)),
                GlassPanelGeometry.decodeSRGB(min(max(stop.blue, 0), 1))
            )
            let own = 0.2126 * linear.x + 0.7152 * linear.y + 0.0722 * linear.z
            guard hueDrift != 0 else { return own }
            let mean = linear.sum() / 3
            let chroma = max((linear * linear).sum() - 3 * mean * mean, 0).squareRoot()
            return min(max(own, mean + 0.478 * chroma), 1)
        }.max() ?? 0
    }
}

extension GlassTint {
    /// ``interiorLuminanceRange`` with `light` over it, anywhere inside
    /// `rect` of the panel at `panelFrame` (points), whatever the
    /// background. The bound takes the brightest stop, at its brightest hue
    /// when the hue drifts.
    ///
    /// `.light` adds at most each emitter's opacity times the brightest
    /// color's luminance (screen never adds more than the light itself);
    /// `.paint` mixes toward the colors by at most the capped opacity per
    /// emitter, which can also lower the floor.
    public func interiorLuminanceRange(
        with light: GlassLight, in rect: CGRect, ofPanel panelFrame: CGRect, bezelWidth: Double
    ) -> ClosedRange<Double> {
        let base = interiorLuminanceRange
        let opacity = light.maximumOpacity(in: rect, ofPanel: panelFrame, bezelWidth: bezelWidth)
        guard opacity > 0 else { return base }
        let ceiling = light.brightestStopLuminance
        // Every emitter adds in turn, so the bound counts them all.
        let count = Double(light.emitters.filter { !$0.colors.isEmpty && $0.intensity > 0 }.count)
        switch light.composite {
        case .light:
            return base.lowerBound...min(base.upperBound + min(count * opacity * ceiling, 1), 1)
        case .paint:
            let cap = min(opacity, GlassLight.maximumPaintOpacity)
            return (base.lowerBound * pow(1 - cap, count))...max(base.upperBound, ceiling)
        }
    }
}
