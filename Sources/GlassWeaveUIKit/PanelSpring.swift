#if canImport(UIKit)
import GlassWeave
import UIKit

extension SurfaceTransition.Spring {
    /// A spring that follows a finger: about a quarter of a second, with a
    /// whisper of overshoot (GW-32, experimental).
    public static let follow = SurfaceTransition.Spring(response: 0.28, dampingFraction: 0.86)
}

/// A value the panel spring rejected: a NaN or infinite component of a frame.
///
/// > Important: Experimental. This API may change before a stable release.
public enum PanelSpringError: Error, Hashable, Sendable {
    /// The component of the frame that held the value.
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case x, y, width, height
    }

    case nonFiniteFrame(Field)
}

/// Moves a panel's frame with an interruptible spring on the surface's effect
/// clock (GW-32).
///
/// > Important: Experimental. This API may change before a stable release.
///
/// ``setTarget(_:)`` springs ``frame`` toward a new frame. Calling it again in
/// flight **retargets without a jump**: the position and the velocity carry
/// over, so a finger that drags a panel, stops, and drags it somewhere else
/// never sees the glass stop or snap; it keeps coasting the way it was going and
/// bends toward the new target. ``jump(to:)`` places the frame at once with no
/// velocity.
///
/// The spring advances by the effect clock (the sum of the clock's deltas,
/// clamped to 0.1 s a tick, in 1/240 s substeps, the same maths as
/// ``SurfaceTransition``) and calls ``frameHandler`` with the new frame on each
/// tick, on the main thread; the app builds its panels from it and gives them to
/// the surface.
///
/// **Pacing.** While the spring moves the surface runs its clock and asks the
/// display for the interaction rates (``GlassMotionClass/interaction``: 80 to
/// 120 Hz at ``GlassQuality/full``, 60 Hz below). The tick that settles the
/// spring is its last: the clock stops and the surface draws nothing more (on
/// demand again). Several springs on one surface share the one clock.
///
/// **Reduce Motion and the quality tiers.** Under Reduce Motion, and at the
/// ``GlassQuality/minimal`` tier, a new target is reached at once: no clock, no
/// velocity. A setting that changes in flight jumps the spring to its target.
/// Reduce Transparency and Increase Contrast change the material, not the
/// motion.
///
/// **Native content.** The spring moves a frame the app reads; it moves no view.
/// A native control that sits on the glass is moved by the app from
/// ``frameHandler`` (its own frame, its own hit testing and accessibility frame
/// follow that frame), and the surface still takes no touches.
///
/// The surface keeps the spring weakly; the app owns it.
@MainActor
public final class PanelSpring {
    /// The spring in use.
    public var spring: SurfaceTransition.Spring

    /// The frame being drawn.
    public var frame: CGRect {
        Self.rect(value)
    }

    /// Where the spring is going.
    public private(set) var target: CGRect

    /// The rate of change of the frame's center, in points per second.
    public var velocity: CGVector {
        CGVector(dx: speed.x + speed.z / 2, dy: speed.y + speed.w / 2)
    }

    /// Called after every change of ``frame``, on the main thread.
    public var frameHandler: (@MainActor (CGRect) -> Void)?
    /// Called once when a moving spring has settled at its target (not for a
    /// jump under Reduce Motion, which has nothing to wait for).
    public var didSettleHandler: (@MainActor () -> Void)?

    private weak var surface: GlassSurfaceView?
    /// The frame as x, y, width, height and its rates of change.
    private var value: SIMD4<Double>
    private var speed = SIMD4<Double>(repeating: 0)
    private var goal: SIMD4<Double>
    private var moving = false
    private var lastTime: Double?
    private var isApplying = false

    /// The spring settles when every component is this close to its target
    /// (points) and slower than ``settleSpeed`` (points per second).
    static let settleDistance = 0.05
    static let settleSpeed = 1.0
    static let substep = 1.0 / 240
    /// Positions and sizes are clamped to this many points.
    static let limit = 100_000.0

    /// Creates a spring at rest at `frame`.
    public init(surface: GlassSurfaceView, frame: CGRect, spring: SurfaceTransition.Spring = .follow) throws(PanelSpringError) {
        let start = try Self.vector(frame)
        self.surface = surface
        self.spring = spring
        self.value = start
        self.goal = start
        self.target = Self.rect(start)
        surface.addEffectClockClient(self)
    }

    /// Whether the spring is moving now (it wants the effect clock).
    public var isMoving: Bool {
        moving
    }

    /// Springs toward `frame`. Calling it in flight retargets without a jump:
    /// the position and the velocity carry over. A NaN or infinite component
    /// throws and changes nothing; a finite one is clamped (a negative size
    /// becomes 0).
    ///
    /// Under Reduce Motion, at the ``GlassQuality/minimal`` tier, or with no
    /// surface, the frame is reached at once.
    public func setTarget(_ frame: CGRect) throws(PanelSpringError) {
        goal = try Self.vector(frame)
        target = Self.rect(goal)
        if jumps || isSettled {
            finish()
            return
        }
        if !moving {
            moving = true
            lastTime = surface?.effectClock.time
        }
        surface?.effectClockClientChanged()
    }

    /// Springs the frame's center to `center`, keeping its size.
    public func setTarget(center: CGPoint) throws(PanelSpringError) {
        let size = target.size
        try setTarget(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
    }

    /// Places the frame at `frame` now: no spring, no velocity, the target
    /// follows. A NaN or infinite component throws.
    public func jump(to frame: CGRect) throws(PanelSpringError) {
        goal = try Self.vector(frame)
        target = Self.rect(goal)
        finish()
    }

    // MARK: Motion

    private var jumps: Bool {
        guard let surface else { return true }
        return surface.accessibilitySettings.reduceMotion || surface.effectiveQuality == .minimal
    }

    private var isSettled: Bool {
        let distance = value - goal
        return max(abs(distance.x), abs(distance.y), abs(distance.z), abs(distance.w)) < Self.settleDistance
            && max(abs(speed.x), abs(speed.y), abs(speed.z), abs(speed.w)) < Self.settleSpeed
    }

    /// Ends the motion at the target and presents it.
    private func finish() {
        let wasMoving = moving
        moving = false
        lastTime = nil
        value = goal
        speed = SIMD4(repeating: 0)
        apply()
        if wasMoving { surface?.effectClockClientChanged() }
    }

    private func apply() {
        isApplying = true
        defer { isApplying = false }
        frameHandler?(frame)
    }

    /// Advances the spring by `dt` seconds: semi-implicit Euler in 1/240 s
    /// substeps, deterministic for a given sequence of steps.
    func advance(by dt: Double) {
        guard dt > 0 else { return }
        let steps = max(Int((dt / Self.substep).rounded(.up)), 1)
        let h = dt / Double(steps)
        let omega = 2 * Double.pi / spring.response
        let damping = 2 * spring.dampingFraction * omega
        for _ in 0..<steps {
            let acceleration = -omega * omega * (value - goal) - damping * speed
            speed += acceleration * h
            value += speed * h
        }
    }

    private static func vector(_ frame: CGRect) throws(PanelSpringError) -> SIMD4<Double> {
        func component(_ number: CGFloat, _ field: PanelSpringError.Field, low: Double) throws(PanelSpringError) -> Double {
            guard number.isFinite else { throw .nonFiniteFrame(field) }
            return min(max(Double(number), low), limit)
        }
        let size = frame.size
        return SIMD4(
            try component(frame.origin.x, .x, low: -limit), try component(frame.origin.y, .y, low: -limit),
            try component(size.width, .width, low: 0), try component(size.height, .height, low: 0)
        )
    }

    private static func rect(_ v: SIMD4<Double>) -> CGRect {
        CGRect(x: v.x, y: v.y, width: max(v.z, 0), height: max(v.w, 0))
    }
}

extension PanelSpring: GlassEffectClockClient {
    var wantsEffectClock: Bool {
        moving
    }

    func effectClockTick(time: Double) {
        guard moving else { return }
        // The first tick of a run only sets its base time; a long gap (a
        // paused or hidden surface) is clamped, so the spring never leaps.
        let elapsed = lastTime.map { min(max(time - $0, 0), 0.1) } ?? 0
        lastTime = time
        if jumps {
            finish()
            return
        }
        advance(by: elapsed)
        if isSettled {
            finish()
            didSettleHandler?()
        } else {
            apply()
        }
    }

    func surfacePresentationChanged() {
        guard !isApplying, moving, jumps else { return }
        finish()
    }
}
#endif
