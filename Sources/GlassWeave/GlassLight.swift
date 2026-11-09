import Foundation

/// Colored light that lives inside a glass panel: pooled along an edge,
/// along an arc, as an orb, or as a four-corner field, flowing slowly while
/// the middle stays exactly clear.
///
/// > Important: Experimental. This API may change before a stable release.
///
/// Native glass cannot show a hue inside itself. GlassWeave's own glass can,
/// because the light is part of the panel's shader: up to four **emitters**
/// are drawn over the glass (after its refraction, tint, edge illumination,
/// glow, and interior), each with up to four color stops. The light is
/// off by default: ``GlassLight/none`` renders the panel exactly as it
/// renders without any light.
///
/// | Property | Unit | Valid range | Default | Meaning |
/// | --- | --- | --- | --- | --- |
/// | ``emitters`` | ``Emitter`` | 0 to ``maximumEmitters`` | none | The light sources, drawn in order. An emitter without colors is dropped. |
/// | ``composite`` | ``Composite`` | — | ``Composite/light`` | `.light` screens the color over the glass and never darkens it; `.paint` mixes toward the color by at most ``maximumPaintOpacity``, so it also shows on white. |
/// | ``centerFade`` | normalized | 0...1 | 1 | How much the light fades toward the middle: its body is multiplied by `1 − centerFade × smoothstep(0.3, 0.85, w)`, with `w` the depth inside the outline divided by half the shorter side (the same as ``GlassInterior/centerFade``). At 1, every pixel deeper than 85 % is the glass without light. |
/// | ``piping`` | normalized | 0...1 | 0.5 | Light piping: how strongly the rim band near an emitter glows in its color, as if the light were carried into the glass's wall. It falls off with the Euclidean distance from the emitter, not along the outline, so it works for any shape. |
/// | ``pipingWidth`` | points | `nil` or 0 to half the shorter side | `nil` | The width of the piped rim band. `nil` uses the panel's `bezelWidth`. |
/// | ``body`` | normalized | 0...1 | 1 | A factor on the light inside the panel. 0 leaves only the piping. |
/// | ``speed`` | multiple of the pace below | 0 to ``maximumSpeed`` | 1 | How fast the light's time runs against the renderer's effect time. 0 is a still frame at phase 0. |
/// | ``hueDrift`` | whole turns per loop | −16...16 | 0 | How many times every color's hue goes around in one ``loopDuration``. Rounded to a whole number so the loop closes. |
/// | ``timeOffset`` | seconds | any finite value | 0 | Added to the renderer's effect time before the phase is taken, to show a chosen moment or to drive the light from the app's own clock. |
///
/// **Loop.** At effect time `t` the light is drawn at ``phase(at:)``:
/// `(t + timeOffset) × speed`, reduced into `0..<loopDuration` seconds in
/// double precision and divided by ``loopDuration``. Flow, hue drift and
/// drift are whole numbers of turns per loop, so `t` and `t + 64 / speed`
/// give identical frames with no seam at the wrap. All motion is computed
/// on the CPU, once per draw; the shader does no time arithmetic.
///
/// **Normalization rule** (the ``GlassParameters`` rule). A NaN or infinite
/// value anywhere, in an emitter beyond the fourth too, is rejected with
/// ``GlassParameterError/nonFiniteLight(_:)`` naming its ``Field``. Finite
/// values out of range are clamped: components and normalized values to
/// 0...1, lengths and angles to the ranges documented on ``Emitter``,
/// angles are reduced into 0..<360, flow and hue drift are rounded to
/// whole turns, and lists are capped (the first four emitters, the first
/// four stops of each). ``GlassRenderer/panel`` reports the light that is
/// drawn.
public struct GlassLight: Hashable, Sendable {
    /// One color of an emitter's palette, in sRGB-encoded components. The
    /// renderer decodes them and interpolates in linear light, as the glow
    /// does.
    public struct Stop: Hashable, Sendable {
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

    /// Where an emitter's light lives. Positions are in **panel unit
    /// space**: the panel scaled to a square, `x` and `y` from −1 to 1 from
    /// the left to the right edge and from the top to the bottom edge, so a
    /// placement means the same for a pill, a circle, or any other shape.
    public enum Placement: Hashable, Sendable {
        /// A half-plane that hugs one edge: full light at the edge, falling
        /// off as `(1 − distance / reach)²` and exactly 0 from `reach` on.
        /// The colors run along the edge, from its left to its right for the
        /// bottom edge.
        ///
        /// - `angle`: degrees, 0 is the top edge and 90 the right edge
        ///   (clockwise, like ``GlassGlow``'s light angle); reduced into
        ///   0..<360.
        /// - `reach`: unit-space distance from the edge, 0...2. 1 reaches
        ///   the center line; 2 reaches the opposite edge.
        case band(angle: Double, reach: Double)
        /// A stretch of the outline, seen from the panel's center, that
        /// lights inward. The colors run along the arc.
        ///
        /// - `angle`: degrees to the arc's center, as for `band`.
        /// - `span`: degrees the arc covers, 0...360; it falls off smoothly
        ///   to nothing at its ends.
        /// - `reach`: how deep it lights, 0...1 of half the panel's
        ///   shorter side.
        case arc(angle: Double, span: Double, reach: Double)
        /// A soft orb whose colors run from its core outward.
        ///
        /// - `x`, `y`: its center in panel unit space, −1...1, y down.
        /// - `radius`: 0...2, as a fraction of half the panel's shorter
        ///   side.
        /// - `stretch`: how much wider than tall it is, 0.25...4.
        case point(x: Double, y: Double, radius: Double, stretch: Double)
        /// A field of color over the whole panel: the emitter's four stops
        /// are its corners, in reading order (top-left, top-right,
        /// bottom-left, bottom-right), blended bilinearly and warped by one
        /// octave of noise. Fewer than four stops repeat the last. It is
        /// strongest at the outline and falls off toward the middle.
        ///
        /// - `warp`: how far the noise bends the blend, 0...1.
        case field(warp: Double)
    }

    /// One light source.
    public struct Emitter: Hashable, Sendable {
        /// Where the light is.
        public var placement: Placement
        /// The palette, up to ``GlassLight/maximumStops`` stops spread
        /// evenly along the emitter's tangent (see ``Placement``) and
        /// interpolated in linear light. For a field they are the corners.
        public var colors: [Stop]
        /// How bright the emitter is at its strongest, 0...1.
        public var intensity: Double
        /// Whole turns the palette flows per ``GlassLight/loopDuration``,
        /// −8...8, rounded to a whole number. 0 is still. For a field, the
        /// warp's noise moves around a loop this many times instead.
        public var flow: Double
        /// How far the emitter wanders over one loop, 0...1: a band
        /// breathes, an arc sways, an orb orbits. 0 is still.
        public var drift: Double

        public init(
            placement: Placement,
            colors: [Stop],
            intensity: Double = 0.8,
            flow: Double = 0,
            drift: Double = 0
        ) {
            self.placement = placement
            self.colors = colors
            self.intensity = intensity
            self.flow = flow
            self.drift = drift
        }
    }

    /// How light combines with the glass.
    public enum Composite: Hashable, Sendable, CaseIterable {
        /// Screen in linear light, `G + L × (1 − G)`: never darkens a
        /// channel, shows best over dark glass.
        case light
        /// Source-over at a capped opacity (``GlassLight/maximumPaintOpacity``):
        /// the color replaces part of the glass, so it also shows on white.
        case paint
    }

    /// A light parameter that held a rejected value; see
    /// ``GlassParameterError/nonFiniteLight(_:)``.
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case colorRed, colorGreen, colorBlue
        case intensity, flow, drift
        case bandAngle, bandReach
        case arcAngle, arcSpan, arcReach
        case pointX, pointY, pointRadius, pointStretch
        case fieldWarp
        case centerFade, piping, pipingWidth, body, speed, hueDrift, timeOffset
    }

    /// The light sources, in drawing order; up to ``maximumEmitters``.
    public var emitters: [Emitter]
    /// How the light combines with the glass.
    public var composite: Composite
    /// How much the light fades toward the middle, 0...1.
    public var centerFade: Double
    /// How strongly the rim near an emitter glows, 0...1.
    public var piping: Double
    /// The width of the piped rim in points, or `nil` for the panel's bezel
    /// width.
    public var pipingWidth: Double?
    /// A factor on the light inside the panel, 0...1; 0 leaves only the
    /// piping.
    public var body: Double
    /// How fast the light's time runs, 0 through ``maximumSpeed``.
    public var speed: Double
    /// Whole turns of hue per loop for every color, −16...16.
    public var hueDrift: Double
    /// Seconds added to the renderer's effect time.
    public var timeOffset: Double

    /// The most emitters one panel draws.
    public static let maximumEmitters = 4
    /// The most stops one emitter uses.
    public static let maximumStops = 4
    /// The fastest light, as a multiple of the pace in ``loopDuration``.
    public static let maximumSpeed = 3.0
    /// The time, in seconds, after which all motion repeats.
    public static let loopDuration = GlassInterior.loopDuration
    /// The most hue turns per loop.
    public static let maximumHueDriftTurns = 16.0
    /// The most palette turns a flow makes per loop.
    public static let maximumFlowTurns = 8.0
    /// The most opacity `.paint` gives one emitter.
    public static let maximumPaintOpacity = 0.85

    /// No light. The panel renders as it would without one.
    public static let none = GlassLight(emitters: [])

    public init(
        emitters: [Emitter],
        composite: Composite = .light,
        centerFade: Double = 1,
        piping: Double = 0.5,
        pipingWidth: Double? = nil,
        body: Double = 1,
        speed: Double = 1,
        hueDrift: Double = 0,
        timeOffset: Double = 0
    ) {
        self.emitters = emitters
        self.composite = composite
        self.centerFade = centerFade
        self.piping = piping
        self.pipingWidth = pipingWidth
        self.body = body
        self.speed = speed
        self.hueDrift = hueDrift
        self.timeOffset = timeOffset
    }

    /// Whether the light changes any pixel: it has an emitter with a color
    /// and an intensity above 0, and either body light or piping.
    public var isVisible: Bool {
        emitters.contains { !$0.colors.isEmpty && $0.intensity > 0 } && (body > 0 || (piping > 0 && pipingWidth != 0))
    }

    /// Whether the light changes over time: it is visible, its speed is
    /// above 0, and some emitter flows or drifts, or the hue drifts. A host
    /// draws new frames for it only while this is true.
    public var isAnimated: Bool {
        guard isVisible, speed > 0 else { return false }
        return hueDrift != 0 || emitters.contains { $0.intensity > 0 && !$0.colors.isEmpty && ($0.flow != 0 || $0.drift > 0) }
    }

    /// Where in the loop the light is at `seconds` of effect time, in
    /// `0..<1`: `(seconds + timeOffset) × speed`, reduced into
    /// `0..<loopDuration` in double precision and divided by it. 0 for a
    /// non-finite time or speed.
    public func phase(at seconds: Double) -> Double {
        let time = (seconds + timeOffset) * speed
        guard time.isFinite else { return 0 }
        let reduced = time.truncatingRemainder(dividingBy: Self.loopDuration)
        let positive = reduced < 0 ? reduced + Self.loopDuration : reduced
        // A tiny negative remainder plus the loop rounds to the loop itself;
        // keep the range half-open. Adding zero also turns -0 into 0.
        return positive >= Self.loopDuration ? 0 : positive / Self.loopDuration + 0
    }
}

extension GlassLight {
    /// Applies the normalization rule.
    package func normalized(maximumLength: Double) throws(GlassParameterError) -> GlassLight {
        let header: [(Field, Double)] = [
            (.centerFade, centerFade), (.piping, piping), (.body, body), (.speed, speed),
            (.hueDrift, hueDrift), (.timeOffset, timeOffset),
        ]
        for (field, value) in header where !value.isFinite {
            throw .nonFiniteLight(field)
        }
        if let pipingWidth, !pipingWidth.isFinite {
            throw .nonFiniteLight(.pipingWidth)
        }
        for emitter in emitters {
            try emitter.validateFinite()
        }
        let unit = { (value: Double) in min(max(value, 0), 1) }
        let kept = emitters.prefix(Self.maximumEmitters).map { $0.normalized() }.filter { !$0.colors.isEmpty }
        guard !kept.isEmpty else { return .none }
        return GlassLight(
            emitters: kept,
            composite: composite,
            centerFade: unit(centerFade),
            piping: unit(piping),
            pipingWidth: pipingWidth.map { min(max($0, 0), maximumLength) },
            body: unit(body),
            speed: min(max(speed, 0), Self.maximumSpeed),
            hueDrift: min(max(hueDrift.rounded(), -Self.maximumHueDriftTurns), Self.maximumHueDriftTurns) + 0,
            timeOffset: timeOffset
        )
    }
}

extension GlassLight.Emitter {
    fileprivate func validateFinite() throws(GlassParameterError) {
        for stop in colors {
            for (field, value) in [
                (GlassLight.Field.colorRed, stop.red), (.colorGreen, stop.green), (.colorBlue, stop.blue),
            ] where !value.isFinite {
                throw .nonFiniteLight(field)
            }
        }
        for (field, value) in [(GlassLight.Field.intensity, intensity), (.flow, flow), (.drift, drift)] where !value.isFinite {
            throw .nonFiniteLight(field)
        }
        let checks: [(GlassLight.Field, [Double])]
        switch placement {
        case let .band(angle, reach): checks = [(.bandAngle, [angle]), (.bandReach, [reach])]
        case let .arc(angle, span, reach): checks = [(.arcAngle, [angle]), (.arcSpan, [span]), (.arcReach, [reach])]
        case let .point(x, y, radius, stretch):
            checks = [(.pointX, [x]), (.pointY, [y]), (.pointRadius, [radius]), (.pointStretch, [stretch])]
        case let .field(warp): checks = [(.fieldWarp, [warp])]
        }
        for (field, values) in checks where values.contains(where: { !$0.isFinite }) {
            throw .nonFiniteLight(field)
        }
    }

    /// The emitter with every value clamped into range (finite values only).
    fileprivate func normalized() -> GlassLight.Emitter {
        let unit = { (value: Double) in min(max(value, 0), 1) }
        let reducedAngle = { (degrees: Double) -> Double in
            let turn = degrees.truncatingRemainder(dividingBy: 360)
            let positive = turn < 0 ? turn + 360 : turn
            return positive >= 360 ? 0 : positive + 0
        }
        let placement: GlassLight.Placement
        switch self.placement {
        case let .band(angle, reach):
            placement = .band(angle: reducedAngle(angle), reach: min(max(reach, 0), 2))
        case let .arc(angle, span, reach):
            placement = .arc(angle: reducedAngle(angle), span: min(max(span, 0), 360), reach: unit(reach))
        case let .point(x, y, radius, stretch):
            placement = .point(
                x: min(max(x, -1), 1), y: min(max(y, -1), 1),
                radius: min(max(radius, 0), 2), stretch: min(max(stretch, 0.25), 4)
            )
        case let .field(warp):
            placement = .field(warp: unit(warp))
        }
        return GlassLight.Emitter(
            placement: placement,
            colors: colors.prefix(GlassLight.maximumStops).map {
                GlassLight.Stop(red: unit($0.red), green: unit($0.green), blue: unit($0.blue))
            },
            intensity: unit(intensity),
            flow: min(max(flow.rounded(), -GlassLight.maximumFlowTurns), GlassLight.maximumFlowTurns) + 0,
            drift: unit(drift)
        )
    }
}
