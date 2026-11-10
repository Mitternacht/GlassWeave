#if canImport(UIKit)
import Foundation
import GlassWeave
import UIKit
#if canImport(CoreMotion) && os(iOS)
import CoreMotion
#endif

/// One reading of the direction of gravity in the device's own frame, with the
/// time it was taken (GW-33).
///
/// > Important: Experimental. This API may change before a stable release.
///
/// The frame is Core Motion's: x to the right of the screen, y toward its top,
/// z out of the screen, and the vector is in units of g, so a phone held upright
/// reads `(0, -1, 0)`, lying face up on a table `(0, 0, -1)`, and with its right
/// edge down `x` is positive. The vector need not have length 1 (a sensor's
/// noise); the angles below use its direction only.
public struct GlassMotionSample: Equatable, Sendable {
    /// Gravity in the device's frame, in g.
    public var gravity: SIMD3<Double>
    /// The time of the reading in seconds, on any clock that only moves forward
    /// (Core Motion's timestamps are seconds since the device started).
    public var timestamp: Double

    public init(gravity: SIMD3<Double>, timestamp: Double) {
        self.gravity = gravity
        self.timestamp = timestamp
    }

    /// A reading of a device held with its screen leaned back by
    /// `leanDegrees` (0 upright, 90 flat and face up) and rolled by
    /// `rollDegrees` (positive: the right edge down). For a lab slider, a
    /// preview, or a test; ``rollDegrees`` and ``leanDegrees`` give the angles back.
    public init(rollDegrees: Double, leanDegrees: Double, timestamp: Double) {
        let roll = rollDegrees * .pi / 180, lean = leanDegrees * .pi / 180
        self.init(
            gravity: SIMD3(sin(roll), -cos(roll) * cos(lean), -cos(roll) * sin(lean)),
            timestamp: timestamp
        )
    }

    /// How far the right edge is down, in degrees (-90 to 90; positive: the
    /// right edge is down). 0 when gravity has no length.
    public var rollDegrees: Double {
        let length = (gravity * gravity).sum().squareRoot()
        guard length > 1e-9 else { return 0 }
        return asin(min(max(gravity.x / length, -1), 1)) * 180 / .pi
    }

    /// How far the screen is leaned back, in degrees: 0 upright, 90 flat and
    /// face up, negative leaning forward. 0 when the reading has no component
    /// in the plane of the screen's long axis and normal.
    public var leanDegrees: Double {
        let a = -gravity.z, b = -gravity.y
        guard abs(a) + abs(b) > 1e-9 else { return 0 }
        return atan2(a, b) * 180 / .pi
    }

    /// The first component that is NaN or infinite, if any.
    var firstNonFinite: GlassTiltLightError.SampleField? {
        if !gravity.x.isFinite { return .gravityX }
        if !gravity.y.isFinite { return .gravityY }
        if !gravity.z.isFinite { return .gravityZ }
        if !timestamp.isFinite { return .timestamp }
        return nil
    }
}

/// Where device motion comes from (GW-33): the real sensor on a device, a fake
/// one in a test, a slider in the simulator.
///
/// > Important: Experimental. This API may change before a stable release.
///
/// A source delivers ``GlassMotionSample``s on the main thread to
/// ``sampleHandler`` **only while it is running**. It starts and stops when
/// told: ``GlassTiltLight`` starts it while a surface that uses it is visible
/// and stops it when the surface hides or an accessibility setting pins the
/// light, so a hidden or still screen costs no sensor time.
@MainActor
public protocol GlassMotionSource: AnyObject {
    /// Whether the source can deliver samples now (the hardware is there).
    var isAvailable: Bool { get }
    /// Whether the source is delivering samples.
    var isRunning: Bool { get }
    /// Receives each sample on the main thread, while running.
    var sampleHandler: (@MainActor (GlassMotionSample) -> Void)? { get set }
    /// Starts delivering samples. Does nothing when already running or not
    /// ``isAvailable``.
    func start()
    /// Stops delivering samples. Does nothing when not running.
    func stop()
}

/// A motion source the app or a test feeds by hand (GW-33): the simulator has no
/// motion hardware, so the laboratory's slider and the tests drive the light
/// through one of these.
///
/// > Important: Experimental. This API may change before a stable release.
///
/// ``send(_:)`` hands a sample to the handler exactly as the sensor would, but
/// only while the source is running, so a surface that is hidden (or a light
/// that Reduce Motion pins) receives nothing.
@MainActor
public final class GlassInjectedMotionSource: GlassMotionSource {
    public let isAvailable: Bool
    public private(set) var isRunning = false
    public var sampleHandler: (@MainActor (GlassMotionSample) -> Void)?
    /// How many times ``start()`` has begun the source.
    public private(set) var startCount = 0
    /// How many times ``stop()`` has ended it.
    public private(set) var stopCount = 0
    /// How many samples ``send(_:)`` has delivered.
    public private(set) var deliveredCount = 0

    /// Creates a source; `isAvailable: false` plays a device without motion
    /// hardware.
    public init(isAvailable: Bool = true) {
        self.isAvailable = isAvailable
    }

    public func start() {
        guard isAvailable, !isRunning else { return }
        isRunning = true
        startCount += 1
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        stopCount += 1
    }

    /// Delivers `sample` to ``sampleHandler`` and returns `true`, or returns
    /// `false` and delivers nothing when the source is not running.
    @discardableResult
    public func send(_ sample: GlassMotionSample) -> Bool {
        guard isRunning else { return false }
        deliveredCount += 1
        sampleHandler?(sample)
        return true
    }
}

#if canImport(CoreMotion) && os(iOS)
/// The device's own motion sensor (GW-33): Core Motion's gravity vector at a
/// low rate.
///
/// > Important: Experimental. This API may change before a stable release. The
/// > simulator has no motion hardware (``isAvailable`` is `false` there), so this
/// > path is wired but not verified without a device.
///
/// It reads `CMDeviceMotion.gravity` at ``updateInterval`` (30 Hz by default;
/// the light only needs a slow, smooth signal) on the main queue, and runs only
/// between ``start()`` and ``stop()``. Device motion needs no permission.
@MainActor
public final class GlassCoreMotionSource: GlassMotionSource {
    /// The slowest and fastest rates ``updateInterval`` accepts, in seconds.
    public static let updateIntervalRange = (1.0 / 60)...(1.0 / 10)

    private let manager: CMMotionManager

    public var sampleHandler: (@MainActor (GlassMotionSample) -> Void)?
    public private(set) var isRunning = false

    /// Seconds between samples, default 1/30, clamped to ``updateIntervalRange``
    /// (a NaN is ignored).
    public var updateInterval: TimeInterval = 1.0 / 30 {
        didSet {
            // Assigning inside the observer does not run it again.
            let value = updateInterval.isFinite ? updateInterval : oldValue
            updateInterval = min(max(value, Self.updateIntervalRange.lowerBound), Self.updateIntervalRange.upperBound)
            if isRunning { manager.deviceMotionUpdateInterval = updateInterval }
        }
    }

    public init(manager: CMMotionManager = CMMotionManager()) {
        self.manager = manager
    }

    public var isAvailable: Bool {
        manager.isDeviceMotionAvailable
    }

    public func start() {
        guard !isRunning, isAvailable else { return }
        isRunning = true
        manager.deviceMotionUpdateInterval = updateInterval
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let gravity = motion.gravity
            let sample = GlassMotionSample(gravity: SIMD3(gravity.x, gravity.y, gravity.z), timestamp: motion.timestamp)
            MainActor.assumeIsolated { self?.deliver(sample) }
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopDeviceMotionUpdates()
    }

    private func deliver(_ sample: GlassMotionSample) {
        guard isRunning else { return }
        sampleHandler?(sample)
    }

    isolated deinit {
        if isRunning { manager.stopDeviceMotionUpdates() }
    }
}
#endif
#endif
