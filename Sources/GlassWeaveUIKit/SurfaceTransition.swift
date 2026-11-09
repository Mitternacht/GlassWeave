#if canImport(UIKit)
import GlassWeave
import UIKit

/// Drives the progress of a surface merge (GW-13) with an interruptible,
/// reversible spring on the surface's effect clock.
///
/// > Important: Experimental. This API may change before a stable release.
///
/// ``setTarget(_:)`` springs ``progress`` toward 0 (apart) or 1 (merged), and
/// ``reverse()`` turns it around at any moment: the spring keeps its value
/// **and** its velocity when the target changes, so a reversal in flight has no
/// jump (the glass keeps coasting the way it was going for a moment, then
/// comes back). Each time the value changes the transition calls the app's
/// `panels` closure and gives the result to the surface, so the merged outline
/// is whatever the app builds from the progress (usually
/// ``GlassSurfaceMerge/shape(progress:)`` in ``GlassParameters/shape``).
///
/// **Clock and pacing.** The transition runs on the surface's effect clock:
/// the surface ticks it on every display update while the spring moves, asks
/// the display for the interaction rates (``GlassMotionClass/interaction``,
/// 80 to 120 Hz at ``GlassQuality/full``, 60 Hz below it), and stops the clock
/// when the spring has settled. After that tick the surface draws nothing more:
/// it is on demand again (0 submissions after it ends). The spring starts again
/// only when the app asks.
///
/// **Reduce Motion and the quality tiers.** Under Reduce Motion, and at the
/// ``GlassQuality/minimal`` tier, a change of target jumps to the end state at
/// once: no clock, no velocity. A setting that changes in flight jumps the
/// transition to its target. Reduce Transparency and Increase Contrast change
/// the material (the opaque body), not the motion, so the outline still moves.
///
/// **Native content.** The glass is decorative. The transition moves nothing
/// but the glass: native buttons keep their frames, their hit testing and their
/// accessibility for the whole transition, and the app fades or moves its text
/// and controls with ordinary UIKit animation (``progressHandler`` and
/// ``didSettleHandler`` say when). See `docs/interaction.md`.
///
/// **Custom to custom.** Both surfaces belong to GlassWeave and are drawn as
/// one panel. `UIGlassEffect` merges through the system's
/// `UIGlassContainerEffect`, a separate material system that this does not
/// touch.
///
/// The surface keeps its transitions weakly; the app owns them.
@MainActor
public final class SurfaceTransition {
    /// A critically damped or slightly under-damped spring.
    public struct Spring: Hashable, Sendable {
        /// The time of one natural period in seconds, clamped to 0.1...2: a
        /// smaller response is a stiffer, faster spring.
        public var response: Double
        /// 1 does not overshoot; below 1 the progress can pass its target
        /// (the merged outline clamps at the ends), clamped to 0.2...2.
        public var dampingFraction: Double

        public init(response: Double = 0.5, dampingFraction: Double = 0.9) {
            self.response = response.isFinite ? min(max(response, 0.1), 2) : 0.5
            self.dampingFraction = dampingFraction.isFinite ? min(max(dampingFraction, 0.2), 2) : 0.9
        }

        /// A calm spring of about half a second that settles without a visible
        /// overshoot.
        public static let standard = Spring()

        /// One integration step of at most `dt` seconds (the caller substeps),
        /// semi-implicit Euler: deterministic for a given sequence of steps.
        static func step(value: Double, velocity: Double, target: Double, spring: Spring, dt: Double) -> (Double, Double) {
            let omega = 2 * Double.pi / spring.response
            let acceleration = -omega * omega * (value - target) - 2 * spring.dampingFraction * omega * velocity
            let v = velocity + acceleration * dt
            return (value + v * dt, v)
        }
    }

    /// The spring in use.
    public var spring: Spring

    /// The progress being drawn, 0 (apart) to 1 (merged): the spring's value
    /// clamped to that range.
    public private(set) var progress: Double
    /// Where the spring is going: 0 or 1, or the progress a scrub left.
    public private(set) var target: Double
    /// The spring's rate of change in progress per second.
    public private(set) var velocity: Double = 0
    /// The last error the panel closure's panels raised (a non-finite value in
    /// the app's own parameters), or `nil`.
    public private(set) var lastError: GlassParameterError?

    /// Called after every change of ``progress``, on the main thread, for
    /// example to fade native text with it.
    public var progressHandler: (@MainActor (Double) -> Void)?
    /// Called once when a moving spring has settled at its target (not for a
    /// jump under Reduce Motion, which has nothing to wait for).
    public var didSettleHandler: (@MainActor () -> Void)?

    private weak var surface: GlassSurfaceView?
    private let panels: @MainActor (Double) -> [GlassPanel]
    /// The spring's unclamped value (it can overshoot).
    private var value: Double
    private var moving = false
    private var lastTime: Double?
    private var isApplying = false

    /// The spring settles when it is this close to its target and slower than
    /// this.
    static let settleDistance = 0.0005
    static let settleSpeed = 0.01
    /// The integration substep, seconds.
    static let substep = 1.0 / 240

    /// Creates a transition and presents its first panels.
    ///
    /// - Parameters:
    ///   - surface: The surface the panels are drawn on.
    ///   - progress: The first progress, clamped to 0...1; a NaN or infinite
    ///     value throws ``GlassParameterError/nonFiniteShape(_:)``.
    ///   - panels: Builds every panel of the surface (the merged one and any
    ///     others) for a progress.
    public init(
        surface: GlassSurfaceView, spring: Spring = .standard, progress: Double = 0,
        panels: @escaping @MainActor (Double) -> [GlassPanel]
    ) throws(GlassParameterError) {
        let start = try GlassSurfaceMerge.normalizedProgress(progress)
        self.surface = surface
        self.spring = spring
        self.progress = start
        self.target = start
        self.value = start
        self.panels = panels
        surface.addEffectClockClient(self)
        apply()
    }

    /// Creates a transition of one merged panel: `frame` with `parameters`,
    /// whose shape is `merge` at the progress, and any `otherPanels` drawn
    /// after it.
    public convenience init(
        surface: GlassSurfaceView, merge: GlassSurfaceMerge, frame: CGRect, parameters: GlassParameters,
        otherPanels: [GlassPanel] = [], spring: Spring = .standard, progress: Double = 0
    ) throws(GlassParameterError) {
        try self.init(surface: surface, spring: spring, progress: progress) { progress in
            var merged = parameters
            // A progress is finite and clamped here; a bad merge value shows up
            // as the shape that the surface rejects.
            merged.shape = (try? merge.shape(progress: progress)) ?? .roundedRectangle
            return [GlassPanel(frame: frame, parameters: merged)] + otherPanels
        }
    }

    /// Whether the spring is moving now (it wants the effect clock).
    public var isMoving: Bool {
        moving
    }

    /// Springs toward `target`, 0 (apart) or 1 (merged) or any value between,
    /// clamped to 0...1; a NaN or infinite one throws. Calling it in flight
    /// retargets without a jump: the value and the velocity carry over.
    ///
    /// Under Reduce Motion and at the ``GlassQuality/minimal`` tier, or with no
    /// surface to draw on, it jumps to `target` at once.
    public func setTarget(_ target: Double) throws(GlassParameterError) {
        let clamped = try GlassSurfaceMerge.normalizedProgress(target)
        self.target = clamped
        if jumps {
            finish()
            return
        }
        guard abs(value - clamped) > Self.settleDistance || abs(velocity) > Self.settleSpeed else {
            finish()
            return
        }
        if !moving {
            moving = true
            lastTime = surface?.effectClock.time
        }
        surface?.effectClockClientChanged()
    }

    /// Turns the transition around: toward 0 if it is nearer to merged (its
    /// target is 0.5 or more), toward 1 otherwise. Works at any moment of the
    /// flight.
    public func reverse() {
        try? setTarget(target >= 0.5 ? 0 : 1)
    }

    /// Sets the progress directly, as a finger on a slider does: no spring, no
    /// velocity, the target follows. Clamped to 0...1; a NaN or infinite value
    /// throws.
    public func scrub(to progress: Double) throws(GlassParameterError) {
        let clamped = try GlassSurfaceMerge.normalizedProgress(progress)
        target = clamped
        finish()
    }

    /// Presents the panels again for the current progress, for example after a
    /// layout change that moved the frame the `panels` closure reads.
    public func refresh() {
        apply()
    }

    // MARK: Motion

    /// Whether a change of target jumps: Reduce Motion or the minimal tier, or
    /// no surface.
    private var jumps: Bool {
        guard let surface else { return true }
        return surface.accessibilitySettings.reduceMotion || surface.effectiveQuality == .minimal
    }

    /// Ends the motion at the target and presents it.
    private func finish() {
        let wasMoving = moving
        moving = false
        lastTime = nil
        value = target
        velocity = 0
        apply()
        if wasMoving { surface?.effectClockClientChanged() }
    }

    /// Presents the panels for the current progress.
    private func apply() {
        progress = min(max(value, 0), 1)
        isApplying = true
        defer { isApplying = false }
        do {
            try surface?.setPanels(panels(progress))
            lastError = nil
        } catch {
            lastError = error
        }
        progressHandler?(progress)
    }

    /// Advances the spring by `dt` seconds.
    func advance(by dt: Double) {
        guard dt > 0 else { return }
        let steps = max(Int((dt / Self.substep).rounded(.up)), 1)
        let h = dt / Double(steps)
        for _ in 0..<steps {
            (value, velocity) = Spring.step(value: value, velocity: velocity, target: target, spring: spring, dt: h)
        }
    }
}

extension SurfaceTransition: GlassEffectClockClient {
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
        if abs(value - target) < Self.settleDistance, abs(velocity) < Self.settleSpeed {
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
