import CoreGraphics
import Foundation

/// How a glass panel answers a finger (GW-12): a soft light that follows the
/// touch inside the glass, a restrained ring that travels out from where the
/// touch began and bends the backdrop a little, and a tiny gleam on the rim
/// nearest the finger.
///
/// > Important: Experimental. This API may change before a stable release.
///
/// Apple's interactive glass answers a touch with a light that gathers under
/// the finger. GlassWeave draws its own: the same quiet restraint, with the
/// extra that the ring is real refraction (it moves the sample of the backdrop
/// that the glass shows) and the gleam obeys the panel's one light direction.
///
/// | Part | What it is |
/// | --- | --- |
/// | Finger light | A soft pool of white light, `fingerRadius` points wide, that follows the finger. It fades in over ``fadeIn`` and out over ``fadeOut``. It brightens the glass toward white (it never darkens) and stays inside the outline. |
/// | Ripple | One ring that starts at the point where the touch began and travels out to `rippleRadius` over ``rippleDuration``, thinning as it goes. It bends the backdrop by at most ``maximumRippleDisplacement`` points times ``ripple``, whatever the settings, and catches the key light on its lit side. |
/// | Gleam | A thin bright line on the outline just inside the rim nearest the finger, brighter on the side facing the light, stronger the closer the finger is. |
///
/// **Deterministic and finite.** The response is a pure function of the touch
/// (its origin, position, when it began and when it ended), the style and the
/// current time on the effect clock: ``state(of:at:)``. The ripple ends by
/// itself after ``rippleDuration``; the finger light lasts as long as the touch
/// plus ``fadeOut``. Nothing in it is random.
///
/// **Off by default.** ``GlassTouch/none`` (the default of
/// ``GlassParameters/touch``) draws nothing: the panel is drawn by the same
/// pipeline variant, with the same bytes, as without this type. A panel draws
/// the response only while a touch that began inside its outline has something
/// to show, in a pipeline variant of its own; frost and fill panels draw no
/// touch response (their variants do not carry it).
///
/// **Normalization.** A non-finite value is rejected with
/// ``GlassParameterError/nonFiniteTouch(_:)`` naming the field; a finite value
/// is clamped: strengths to 0...1, ``fingerRadius`` to 0...400 points,
/// ``rippleRadius`` to 0...600 points, ``rippleDuration`` to 0.05...5 seconds,
/// ``fadeIn`` and ``fadeOut`` to 0...3 seconds.
///
/// The touches reach the renderer through ``GlassRenderer/setTouches(_:)``;
/// ``GlassSurfaceView`` in the UIKit product turns the app's touch forwarding
/// into them, paces the display for them, and stops drawing after they settle.
public struct GlassTouch: Hashable, Sendable {
    /// The finger light's strength at full level, 0...1; 0 draws no light.
    public var fingerLight: Double
    /// The finger light's radius, in points.
    public var fingerRadius: Double
    /// The ripple's strength, 0...1; 0 draws no ripple. One bends the backdrop
    /// by ``maximumRippleDisplacement`` points at the ring's strongest.
    public var ripple: Double
    /// How far the ring travels from where the touch began, in points.
    public var rippleRadius: Double
    /// How long the ring takes to travel and fade, in seconds.
    public var rippleDuration: Double
    /// The rim gleam's strength, 0...1; 0 draws none.
    public var gleam: Double
    /// How long the finger light takes to come up when the touch begins, in
    /// seconds; 0 shows it at once.
    public var fadeIn: Double
    /// How long the finger light and the gleam take to fade after the touch
    /// ends, in seconds; 0 removes them at once.
    public var fadeOut: Double

    /// The hard bound on the ring's displacement of the backdrop, in points,
    /// at ``ripple`` 1. The displacement never exceeds ``ripple`` times this,
    /// at any time and position.
    public static let maximumRippleDisplacement = 8.0

    /// The most touches one draw answers.
    public static let maximumTouchCount = 2

    public init(
        fingerLight: Double = 0, fingerRadius: Double = 44,
        ripple: Double = 0, rippleRadius: Double = 120, rippleDuration: Double = 0.85,
        gleam: Double = 0, fadeIn: Double = 0.10, fadeOut: Double = 0.35
    ) {
        self.fingerLight = fingerLight
        self.fingerRadius = fingerRadius
        self.ripple = ripple
        self.rippleRadius = rippleRadius
        self.rippleDuration = rippleDuration
        self.gleam = gleam
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    /// No touch response. The default.
    public static let none = GlassTouch()

    /// A restrained response: a soft, wide pool of light under the finger, a
    /// barely-there ring (a wide, soft swell that moves the backdrop about two
    /// points at most, hard to see in a still frame) and a faint gleam on the
    /// rim, in the same family as Apple's interactive glass.
    public static let standard = GlassTouch(fingerLight: 0.55, fingerRadius: 58, ripple: 0.32, rippleRadius: 140, gleam: 0.45)

    /// Whether the response can draw anything.
    public var isActive: Bool {
        fingerLight > 0 || hasRipple || gleam > 0
    }

    /// Whether the ring can draw.
    public var hasRipple: Bool {
        ripple > 0 && rippleRadius > 0
    }

    /// Whether the response changes with time after a touch begins or ends: a
    /// ring, or a light that fades. A response that does not (no ring, no
    /// fade) needs no effect clock; it is drawn as the touches change.
    public var isAnimated: Bool {
        isActive && (hasRipple || fadeIn > 0 || fadeOut > 0)
    }

    /// The part of the response that remains when motion is reduced: no ring,
    /// and the light and the gleam appear and disappear with the finger.
    public var withoutMotion: GlassTouch {
        var still = self
        still.ripple = 0
        still.fadeIn = 0
        still.fadeOut = 0
        return still
    }

    /// The response at the balanced quality tier: the ring is dropped.
    public var withoutRipple: GlassTouch {
        var reduced = self
        reduced.ripple = 0
        return reduced
    }

    /// The named values a ``GlassParameterError`` can refuse.
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case fingerLight
        case fingerRadius
        case ripple
        case rippleRadius
        case rippleDuration
        case gleam
        case fadeIn
        case fadeOut
        /// A ``GlassTouchPoint/origin`` coordinate.
        case originX
        case originY
        /// A ``GlassTouchPoint/position`` coordinate.
        case positionX
        case positionY
        case beganAt
        case endedAt
    }

    /// Applies the normalization rule: rejects non-finite values and clamps
    /// finite ones into range.
    func normalized() throws(GlassParameterError) -> GlassTouch {
        let checks: [(Field, Double)] = [
            (.fingerLight, fingerLight), (.fingerRadius, fingerRadius), (.ripple, ripple),
            (.rippleRadius, rippleRadius), (.rippleDuration, rippleDuration), (.gleam, gleam),
            (.fadeIn, fadeIn), (.fadeOut, fadeOut),
        ]
        for (field, value) in checks where !value.isFinite {
            throw .nonFiniteTouch(field)
        }
        let unit = { (value: Double) in min(max(value, 0), 1) }
        return GlassTouch(
            fingerLight: unit(fingerLight),
            fingerRadius: min(max(fingerRadius, 0), 400),
            ripple: unit(ripple),
            rippleRadius: min(max(rippleRadius, 0), 600),
            rippleDuration: min(max(rippleDuration, 0.05), 5),
            gleam: unit(gleam),
            fadeIn: min(max(fadeIn, 0), 3),
            fadeOut: min(max(fadeOut, 0), 3)
        )
    }
}

/// One finger on the glass, in the surface's points and on the effect clock
/// (GW-12).
///
/// > Important: Experimental. This API may change before a stable release.
public struct GlassTouchPoint: Hashable, Sendable {
    /// Where the touch began, in points in the surface's space (the space the
    /// panels' frames use). The ripple spreads from here, and the touch drives
    /// the panel whose outline contains it.
    public var origin: CGPoint
    /// Where the finger is now. The finger light and the gleam follow it; it
    /// equals ``origin`` until the finger moves.
    public var position: CGPoint
    /// The effect-clock time, in seconds, at which the touch began.
    public var beganAt: Double
    /// The effect-clock time at which the touch ended or was cancelled, or
    /// `nil` while the finger is down.
    public var endedAt: Double?

    public init(origin: CGPoint, position: CGPoint? = nil, beganAt: Double, endedAt: Double? = nil) {
        self.origin = origin
        self.position = position ?? origin
        self.beganAt = beganAt
        self.endedAt = endedAt
    }

    /// Rejects non-finite values.
    func checked() throws(GlassParameterError) {
        guard origin.x.isFinite else { throw .nonFiniteTouch(.originX) }
        guard origin.y.isFinite else { throw .nonFiniteTouch(.originY) }
        guard position.x.isFinite else { throw .nonFiniteTouch(.positionX) }
        guard position.y.isFinite else { throw .nonFiniteTouch(.positionY) }
        guard beganAt.isFinite else { throw .nonFiniteTouch(.beganAt) }
        if let endedAt, !endedAt.isFinite { throw .nonFiniteTouch(.endedAt) }
    }
}

/// What one touch shows at one moment (GW-12): the output of
/// ``GlassTouch/state(of:at:)``.
///
/// > Important: Experimental. This API may change before a stable release.
public struct GlassTouchState: Equatable, Sendable {
    /// The finger light's level, 0...1, its fade applied.
    public var light: Double
    /// The finger light's radius scale, 0.82...1: the pool grows a little as it
    /// comes up.
    public var lightScale: Double
    /// The ring's radius from the touch's origin, in points.
    public var ringRadius: Double
    /// The ring's width, in points.
    public var ringWidth: Double
    /// The ring's strength, 0...``GlassTouch/ripple``.
    public var ringStrength: Double
    /// The ring's peak displacement of the backdrop now, in points: at most
    /// ``GlassTouch/maximumRippleDisplacement`` times ``GlassTouch/ripple``.
    public var ringDisplacement: Double
    /// The rim gleam's level, 0...``GlassTouch/gleam``.
    public var gleam: Double
    /// Nothing changes with time any more unless the touch moves or ends: the
    /// finger is down and the fade-in and the ring are over.
    public var isSteady: Bool
    /// The touch has ended and nothing of it is left to draw.
    public var isSettled: Bool

    /// Whether the touch draws anything at this moment.
    public var isVisible: Bool {
        light > 0 || ringDisplacement > 0 || gleam > 0
    }
}

extension GlassTouch {
    /// What `touch` shows at `time` on the effect clock, for this style: a
    /// pure function of its arguments, with a finite duration (the ring ends
    /// after ``rippleDuration``, the light ``fadeOut`` after the touch ends)
    /// and a displacement bounded by ``maximumRippleDisplacement``. A time
    /// before the touch began shows nothing.
    ///
    /// Reads the style as given: normalize it first if it came from outside.
    public func state(of touch: GlassTouchPoint, at time: Double) -> GlassTouchState {
        let age = time - touch.beganAt
        guard age >= 0 else {
            return GlassTouchState(
                light: 0, lightScale: 0.82, ringRadius: 0, ringWidth: 0, ringStrength: 0, ringDisplacement: 0,
                gleam: 0, isSteady: false, isSettled: false
            )
        }
        // The light comes up with the finger and fades after it.
        let rise = fadeIn > 0 ? Self.smooth(age / fadeIn) : 1
        var fall = 1.0
        var since = 0.0
        var ended = false
        if let endedAt = touch.endedAt, time >= endedAt {
            ended = true
            since = time - endedAt
            fall = fadeOut > 0 ? 1 - Self.smooth(since / fadeOut) : 0
        }
        let level = rise * fall
        let light = fingerLight > 0 ? level : 0
        let gleam = self.gleam * level

        // One ring, once.
        var ringRadius = 0.0
        var ringWidth = 0.0
        var strength = 0.0
        let rippleOver = !hasRipple || age >= rippleDuration
        if hasRipple, age < rippleDuration {
            let u = age / rippleDuration
            ringRadius = rippleRadius * (1 - (1 - u) * (1 - u))
            ringWidth = 22 + 0.2 * ringRadius
            strength = ripple * Self.smooth(u / 0.12) * pow(1 - u, 1.6)
        }
        let fadeOver = ended && since >= fadeOut
        let riseOver = fadeIn <= 0 || age >= fadeIn
        return GlassTouchState(
            light: light,
            lightScale: 0.82 + 0.18 * rise,
            ringRadius: ringRadius,
            ringWidth: ringWidth,
            ringStrength: strength,
            ringDisplacement: strength * Self.maximumRippleDisplacement,
            gleam: gleam,
            isSteady: !ended && riseOver && rippleOver,
            isSettled: fadeOver && rippleOver
        )
    }

    /// The effect-clock time after which `touch` shows nothing, or `nil` while
    /// the finger is down.
    public func settlingTime(of touch: GlassTouchPoint) -> Double? {
        guard let endedAt = touch.endedAt else { return nil }
        return max(endedAt + fadeOut, hasRipple ? touch.beganAt + rippleDuration : touch.beganAt)
    }

    /// Smoothstep of `x` clamped to 0...1.
    static func smooth(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
