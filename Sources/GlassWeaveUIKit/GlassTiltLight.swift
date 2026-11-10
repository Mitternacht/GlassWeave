#if canImport(UIKit)
import Foundation
import GlassWeave
import UIKit

/// A value the tilt light rejected, naming the field (GW-33).
///
/// > Important: Experimental. This API may change before a stable release.
public enum GlassTiltLightError: Error, Hashable, Sendable {
    /// A field of ``GlassTiltLight/Configuration``.
    public enum ConfigurationField: String, Hashable, Sendable, CaseIterable {
        case maximumAzimuth, maximumElevation, fullTilt, neutralLean, timeConstant
    }

    /// A component of a ``GlassMotionSample``.
    public enum SampleField: String, Hashable, Sendable, CaseIterable {
        case gravityX, gravityY, gravityZ, timestamp
    }

    /// A configuration field was NaN or infinite.
    case nonFiniteConfiguration(ConfigurationField)
    /// A sample's component was NaN or infinite.
    case nonFiniteSample(SampleField)
}

/// Moves the light of a glass surface with the tilt of the device (GW-33): the
/// light model's azimuth and elevation offset follow a ``GlassMotionSource``
/// through a low-pass filter, by a small, bounded amount.
///
/// > Important: Experimental. This API may change before a stable release.
///
/// **What moves.** The offset of ``GlassRenderer/setLightOffset(azimuth:elevation:)``
/// (the light terms of every panel whose ``GlassParameters/lighting`` is not
/// ``GlassLighting/legacy``, and the glow that follows the key light). It moves no
/// panel, rebuilds nothing, and creates no renderer: one cheap call on the existing
/// renderer, followed by one requested frame.
///
/// **The physics.** A fixed lamp in the room lights a screen from a direction that
/// changes when the screen turns. Rolling the device so its right edge goes down
/// swings the lamp, as the screen sees it, toward the left: the azimuth offset is
/// negative (counter-clockwise; 0 is the top of the screen, as in the light model).
/// Leaning the screen back toward flat raises the lamp over it: the elevation
/// offset grows. Both are measured from gravity alone (``GlassMotionSample``), so the
/// device may be held in any posture; the lean is measured from
/// ``Configuration/neutralLean`` so a normal grip leaves the authored light where it
/// is.
///
/// **Bounds.** Each offset is the tilt (in degrees from neutral) divided by
/// ``Configuration/fullTilt``, clamped to -1...1, times ``Configuration/maximumAzimuth``
/// (default 30 degrees, the tilt itself at full tilt, never more than 60) or ``Configuration/maximumElevation``
/// (default 12, never more than 30). So a sample can never move the light further
/// than that, whatever the device does, and the low-pass filter (an exponential
/// smoother with time constant ``Configuration/timeConstant``, 0.25 s by default) is a
/// convex combination of values inside that range: it stays inside it too.
///
/// **Low frequency.** Samples arrive at the source's rate (30 Hz for
/// ``GlassCoreMotionSource``). The light is applied only when the filtered offset has
/// moved by ``applyThreshold`` degrees since the last application, so a device lying
/// still draws nothing and a settled light stops requesting frames.
///
/// **Lifetime.** The source runs only while it is needed: the surface is visible
/// (``GlassSurfaceView/isVisible``) and no accessibility setting pins the light. It
/// starts when the surface appears and stops when it hides, so a hidden screen costs
/// no sensor time. The light installs itself on the surface's
/// ``GlassSurfaceView/visibilityHandler`` and
/// ``GlassSurfaceView/accessibilitySettingsHandler`` and calls the handler that was
/// there before; an app that replaces either handler later must call
/// ``refresh()`` from its own.
///
/// **Accessibility.**
///
/// | Setting | Behavior |
/// | --- | --- |
/// | Reduce Motion | The light is **pinned** at the authored direction (offset 0, 0): the source stops, samples are ignored, and the offset goes back at once with no glide. |
/// | Reduce Transparency, Increase Contrast | The light terms the tilt moves are removed or evenly lit by the policy (``GlassAccessibilityPolicy``), so nothing visible would change: the same pin applies, and the sensor does not run. |
/// | Quality tiers | Not affected: the light costs one frame per change, and a still device costs none. |
///
/// The light keeps the surface only weakly. Call ``invalidate()`` when the screen
/// goes away; a deinitialized light also stops its source.
@MainActor
public final class GlassTiltLight {
    /// The tuning of the mapping and the filter, with the bounds each field is
    /// clamped to.
    public struct Configuration: Equatable, Sendable {
        /// The widest azimuth offset in degrees, 0...60 (``azimuthLimit``). Default 30.
        public var maximumAzimuth: Double
        /// The widest elevation offset in degrees, 0...30 (``elevationLimit``). Default 12.
        public var maximumElevation: Double
        /// The tilt in degrees that reaches the widest offset, 5...90. Default 30.
        public var fullTilt: Double
        /// The lean, in degrees, at which the elevation offset is 0: 0 upright,
        /// 90 flat, range 0...90. Default 40, a normal grip.
        public var neutralLean: Double
        /// The time constant of the low-pass filter in seconds, 0.02...2. Default
        /// 0.25: the light reaches 95 percent of a new target in about 0.75 s.
        public var timeConstant: Double

        public init(
            maximumAzimuth: Double = 30, maximumElevation: Double = 12, fullTilt: Double = 30,
            neutralLean: Double = 40, timeConstant: Double = 0.25
        ) {
            self.maximumAzimuth = maximumAzimuth
            self.maximumElevation = maximumElevation
            self.fullTilt = fullTilt
            self.neutralLean = neutralLean
            self.timeConstant = timeConstant
        }

        /// The configuration with every field clamped into its range. A NaN or
        /// infinite field throws ``GlassTiltLightError/nonFiniteConfiguration(_:)``
        /// naming it.
        public func normalized() throws(GlassTiltLightError) -> Configuration {
            func clamp(_ value: Double, _ field: GlassTiltLightError.ConfigurationField, _ range: ClosedRange<Double>) throws(GlassTiltLightError) -> Double {
                guard value.isFinite else { throw .nonFiniteConfiguration(field) }
                return min(max(value, range.lowerBound), range.upperBound)
            }
            return Configuration(
                maximumAzimuth: try clamp(maximumAzimuth, .maximumAzimuth, 0...azimuthLimit),
                maximumElevation: try clamp(maximumElevation, .maximumElevation, 0...elevationLimit),
                fullTilt: try clamp(fullTilt, .fullTilt, 5...90),
                neutralLean: try clamp(neutralLean, .neutralLean, 0...90),
                timeConstant: try clamp(timeConstant, .timeConstant, 0.02...2)
            )
        }
    }

    /// The most the azimuth offset can ever be, in degrees, whatever the
    /// configuration says.
    public nonisolated static let azimuthLimit = 60.0
    /// The most the elevation offset can ever be, in degrees.
    public nonisolated static let elevationLimit = 30.0
    /// The light is applied when the filtered offset has moved this many degrees
    /// since it was last applied.
    public nonisolated static let applyThreshold = 0.02
    /// The step assumed for the first sample after a start, in seconds.
    public nonisolated static let nominalInterval = 1.0 / 30
    /// The longest step the filter takes in one sample, in seconds, so a stale
    /// timestamp never makes the light leap.
    public nonisolated static let longestStep = 0.25

    /// The tuning in use (normalized).
    public let configuration: Configuration

    /// The source in use. Replacing it stops the old one and starts the new one if
    /// the light wants the sensor.
    public var source: any GlassMotionSource {
        didSet {
            oldValue.stop()
            oldValue.sampleHandler = nil
            connectSource()
            refresh()
        }
    }

    /// The offset last given to the renderer: the filtered tilt, in degrees.
    public private(set) var offset: (azimuth: Double, elevation: Double) = (0, 0)

    /// Whether an accessibility setting holds the light at the authored direction.
    public private(set) var isPinned = false

    /// How many times the light has been given to the renderer.
    public private(set) var appliedCount = 0

    private weak var surface: GlassSurfaceView?
    private var filtered = SIMD2<Double>(0, 0)
    private var lastTimestamp: Double?
    private var traitRegistration: (any UITraitChangeRegistration)?
    private var isInvalidated = false

    /// Creates a light that follows `source` on `surface` and starts the source
    /// now if the surface is visible and no accessibility setting pins the light.
    /// `configuration` is normalized first; a NaN or infinite field throws.
    public init(
        surface: GlassSurfaceView, source: any GlassMotionSource, configuration: Configuration = Configuration()
    ) throws(GlassTiltLightError) {
        self.configuration = try configuration.normalized()
        self.surface = surface
        self.source = source
        connectSource()
        let previousVisibility = surface.visibilityHandler
        surface.visibilityHandler = { [weak self] visible in
            previousVisibility?(visible)
            MainActor.assumeIsolated { self?.refresh() }
        }
        let previousSettings = surface.accessibilitySettingsHandler
        surface.accessibilitySettingsHandler = { [weak self] settings in
            previousSettings?(settings)
            MainActor.assumeIsolated { self?.refresh() }
        }
        traitRegistration = surface.registerForTraitChanges([UITraitAccessibilityContrast.self]) { [weak self] (_: GlassSurfaceView, _) in
            self?.refresh()
        }
        refresh()
    }

    isolated deinit {
        source.stop()
    }

    /// The offset a steady device attitude gives, with no smoothing: the
    /// mapping alone. `configuration` should be normalized (the initializer does it).
    public static func offset(
        for sample: GlassMotionSample, configuration: Configuration
    ) -> (azimuth: Double, elevation: Double) {
        let roll = max(min(sample.rollDegrees / configuration.fullTilt, 1), -1)
        let lean = max(min((sample.leanDegrees - configuration.neutralLean) / configuration.fullTilt, 1), -1)
        // Right edge down (positive roll) turns the lamp toward the left of the
        // screen; a flatter screen raises it.
        return (-roll * configuration.maximumAzimuth + 0, lean * configuration.maximumElevation)
    }

    /// Gives the light one reading, as a source does. A NaN or infinite component
    /// throws ``GlassTiltLightError/nonFiniteSample(_:)`` naming it and changes
    /// nothing (a source's own non-finite samples are ignored). Ignored while
    /// pinned.
    public func ingest(_ sample: GlassMotionSample) throws(GlassTiltLightError) {
        if let field = sample.firstNonFinite { throw .nonFiniteSample(field) }
        guard !isPinned, !isInvalidated else { return }
        let target = Self.offset(for: sample, configuration: configuration)
        let step = lastTimestamp.map { min(max(sample.timestamp - $0, 0), Self.longestStep) } ?? Self.nominalInterval
        lastTimestamp = sample.timestamp
        let blend = 1 - exp(-step / configuration.timeConstant)
        filtered += (SIMD2(target.azimuth, target.elevation) - filtered) * blend
        applyIfMoved()
    }

    /// Starts or stops the source and pins or frees the light to match the
    /// surface's visibility and accessibility settings. The light calls it
    /// itself; call it from your own handler if you replace the surface's
    /// ``GlassSurfaceView/visibilityHandler`` or
    /// ``GlassSurfaceView/accessibilitySettingsHandler`` after creating the light.
    public func refresh() {
        guard !isInvalidated else { return }
        guard let surface else {
            source.stop()
            return
        }
        let settings = surface.accessibilitySettings
        let pinned = settings.reduceMotion || settings.reduceTransparency
            || surface.traitCollection.accessibilityContrast == .high
        if pinned {
            isPinned = true
            source.stop()
            lastTimestamp = nil
            filtered = .zero
            applyIfMoved(force: true)
            return
        }
        isPinned = false
        if surface.isVisible {
            if !source.isRunning { lastTimestamp = nil }
            source.start()
        } else {
            source.stop()
        }
    }

    /// Stops the source, returns the light to the authored direction, and lets go
    /// of the surface. Call it when the screen that uses the light goes away.
    public func invalidate() {
        guard !isInvalidated else { return }
        source.stop()
        source.sampleHandler = nil
        filtered = .zero
        applyIfMoved(force: true)
        isInvalidated = true
        if let surface, let traitRegistration { surface.unregisterForTraitChanges(traitRegistration) }
        traitRegistration = nil
        surface = nil
    }

    // MARK: Applying

    private func connectSource() {
        source.sampleHandler = { [weak self] sample in
            guard let self else { return }
            // A source never sends a non-finite value; one that does is ignored.
            try? ingest(sample)
        }
    }

    /// Gives the renderer the filtered offset when it has moved by the threshold
    /// (or at all, with `force`: a pin must land exactly on the authored light)
    /// and asks for one frame.
    private func applyIfMoved(force: Bool = false) {
        guard let surface else { return }
        let distance = max(abs(filtered.x - offset.azimuth), abs(filtered.y - offset.elevation))
        guard distance >= Self.applyThreshold || (force && distance > 0) else { return }
        offset = (filtered.x, filtered.y)
        // Both values are finite and inside the bounds, so this cannot throw.
        try? surface.renderer.setLightOffset(azimuth: offset.azimuth, elevation: offset.elevation)
        appliedCount += 1
        surface.requestFrame()
    }
}
#endif
