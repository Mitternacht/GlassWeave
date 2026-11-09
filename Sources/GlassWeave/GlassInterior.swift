import Foundation

/// An animated, procedural interior inside a glass panel's outline: energy
/// filaments, radial rays, or rising embers, in its own colors, fading
/// toward a see-through middle.
///
/// The interior is light: its premultiplied color is screened over the glass
/// (after the glass's refraction, tint, edge illumination, and glow) in
/// linear light, `G + L × (1 − G)` per channel, so it never darkens the glass
/// and shows best over darker glass. Every pixel is a deterministic function
/// of the panel, the interior's values, and the interior time: the same seed
/// and time always give the same bytes.
///
/// | Property | Unit | Valid range | Default | Meaning |
/// | --- | --- | --- | --- | --- |
/// | ``effect`` | ``Effect`` | — | — | Which pattern to draw; ``Effect/none`` draws nothing. |
/// | ``colors`` | ``Color`` | 0 to ``maximumColors`` colors | none | A ramp from the pattern's faintest to its brightest parts, interpolated in linear light: one color is a single hue; two or three are spread evenly over the ramp. No colors draws nothing. |
/// | ``intensity`` | normalized | 0...1 | 0.8 | Opacity of the brightest parts of the pattern. |
/// | ``speed`` | multiple of the effect's own pace | 0 to ``maximumSpeed`` | 1 | How fast interior time runs against the renderer's effect time. 0 is a still pattern. |
/// | ``seed`` | — | any `UInt32` | 0 | Picks one of many patterns of the same kind. |
/// | ``centerFade`` | normalized | 0...1 | 1 | How much the interior fades toward the middle (below). At 1 the middle is exactly the glass without an interior. |
///
/// **Interior time.** At effect time `t` (``GlassRenderer/effectTime``),
/// the interior is drawn at ``phase(at:)``: `t × speed`, reduced into
/// `0..<loopDuration` in double precision. Every effect repeats after
/// ``loopDuration`` seconds of interior time, so a long-running clock keeps
/// its accuracy. Changing ``speed`` while the interior runs moves it to the
/// phase of the new speed.
///
/// **Center fade.** With `w` the depth inside the outline divided by half
/// the panel's shorter side (0 at the outline, 1 at the deepest points: the
/// center of a circle, the center line of a capsule), the interior's opacity
/// is multiplied by `1 − centerFade × smoothstep(0.3, 0.85, w)`: unchanged in
/// the outer 30 % of the depth, falling smoothly to `1 − centerFade` at 85 %
/// and beyond. At ``centerFade`` 1, every pixel deeper than 85 % is exactly
/// the glass without an interior, so the middle stays see-through.
///
/// **Scale.** Patterns are laid out in points. Energy and rays scale with
/// half the panel's shorter side, but never below 12 points, so a small or
/// thin panel gets no detail finer than its pixels; flames and sparks have
/// fixed sizes in points and follow the panel's height.
///
/// **Extent.** Energy and rays draw only inside the outline. Embers also
/// let their sparks rise past the top half of the outline into the glow's
/// halo (``GlassGlow/haloRadius``), fading as `(1 − distance / haloRadius)²`
/// to exactly zero at the halo's radius; without a halo, sparks stop at the
/// outline.
///
/// **Normalization rule** (the ``GlassParameters`` rule): a NaN or infinite
/// color component, intensity, speed, or center fade is rejected with
/// ``GlassParameterError/nonFinite(_:)`` naming its field. Finite values out
/// of range are clamped: color components, intensity, and center fade to
/// 0...1, speed to 0 through ``maximumSpeed``. Only the first
/// ``maximumColors`` colors are kept. An interior with ``Effect/none`` or
/// without colors becomes ``none``. ``GlassRenderer/panel`` reports the
/// interior drawn.
public struct GlassInterior: Hashable, Sendable {
    /// The pattern an interior draws.
    public enum Effect: Hashable, Sendable, CaseIterable {
        /// Nothing.
        case none
        /// Thin filaments of warped noise with a faint haze around
        /// them, turning slowly around the center (once per
        /// ``GlassInterior/loopDuration`` of interior time) and evolving,
        /// brighter toward the rim, like a plasma orb.
        case energy
        /// Thirteen soft beams and twenty-nine thin rays radiating from the
        /// center, turning in opposite directions and twinkling, with
        /// brightness flowing outward, like a sun. They fade in away from
        /// the center, where they would be finer than the pixels.
        case rays
        /// Flame tongues rising from the bottom edge, hottest at their base,
        /// and twelve sparks that rise through the panel and may leave its
        /// top half into the halo.
        case embers
    }

    /// One color of an interior's ramp.
    public struct Color: Hashable, Sendable {
        /// sRGB-encoded red, 0...1.
        public var red: Double
        /// sRGB-encoded green, 0...1.
        public var green: Double
        /// sRGB-encoded blue, 0...1.
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// The pattern drawn.
    public var effect: Effect
    /// The color ramp, faintest first; up to ``maximumColors``.
    public var colors: [Color]
    /// Opacity of the pattern's brightest parts, 0...1.
    public var intensity: Double
    /// How fast interior time runs, 0 through ``maximumSpeed``; 0 is still.
    public var speed: Double
    /// Picks the pattern.
    public var seed: UInt32
    /// How much the interior fades toward the middle, 0...1.
    public var centerFade: Double

    /// The most colors a ramp uses.
    public static let maximumColors = 3

    /// The fastest interior, as a multiple of each effect's own pace. At
    /// speed 1 each effect's noise moves through at most 0.5 lattice cells a
    /// second, so at this maximum at most 1.5: below the three flashes a
    /// second that accessibility guidance (WCAG 2.3.1) treats as a risk.
    public static let maximumSpeed = 3.0

    /// The interior time, in seconds, after which every effect repeats.
    public static let loopDuration = 64.0

    /// No interior. The panel renders as it would without one.
    public static let none = GlassInterior(effect: .none, colors: [])

    public init(
        effect: Effect,
        colors: [Color],
        intensity: Double = 0.8,
        speed: Double = 1,
        seed: UInt32 = 0,
        centerFade: Double = 1
    ) {
        self.effect = effect
        self.colors = colors
        self.intensity = intensity
        self.speed = speed
        self.seed = seed
        self.centerFade = centerFade
    }

    /// Whether the interior changes any pixel: it has an effect, a color,
    /// and an intensity above 0.
    public var isVisible: Bool {
        effect != .none && !colors.isEmpty && intensity > 0
    }

    /// Whether the interior changes over time: it is visible and its speed
    /// is above 0. A host draws new frames for it only while this is true.
    public var isAnimated: Bool {
        isVisible && speed > 0
    }

    /// The interior time at `seconds` of effect time: `seconds × speed`
    /// reduced into `0..<loopDuration`, in double precision. 0 for a
    /// non-finite time or speed.
    public func phase(at seconds: Double) -> Double {
        let time = seconds * speed
        guard time.isFinite else { return 0 }
        let reduced = time.truncatingRemainder(dividingBy: Self.loopDuration)
        let positive = reduced < 0 ? reduced + Self.loopDuration : reduced
        // A tiny negative remainder plus the loop rounds to the loop itself;
        // keep the range half-open. Adding zero also turns -0 into 0.
        return positive >= Self.loopDuration ? 0 : positive + 0
    }
}

extension GlassInterior {
    /// Applies the normalization rule.
    package func normalized() throws(GlassParameterError) -> GlassInterior {
        for color in colors {
            for (field, value) in [
                (GlassParameterError.Field.interiorColorRed, color.red),
                (.interiorColorGreen, color.green),
                (.interiorColorBlue, color.blue),
            ] where !value.isFinite {
                throw .nonFinite(field)
            }
        }
        let checks: [(GlassParameterError.Field, Double)] = [
            (.interiorIntensity, intensity), (.interiorSpeed, speed), (.interiorCenterFade, centerFade),
        ]
        for (field, value) in checks where !value.isFinite {
            throw .nonFinite(field)
        }
        guard effect != .none, !colors.isEmpty else { return .none }
        let unit = { (value: Double) in min(max(value, 0), 1) }
        return GlassInterior(
            effect: effect,
            colors: colors.prefix(Self.maximumColors).map {
                Color(red: unit($0.red), green: unit($0.green), blue: unit($0.blue))
            },
            intensity: unit(intensity),
            speed: min(max(speed, 0), Self.maximumSpeed),
            seed: seed,
            centerFade: unit(centerFade)
        )
    }
}
