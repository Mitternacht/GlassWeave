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
