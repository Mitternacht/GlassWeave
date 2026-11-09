/// How fast the app wants a surface's glass to move, by kind of motion.
///
/// **Experimental API** (GW-27).
///
/// A surface takes no touches, so it cannot tell a drag from a rest: the app
/// declares the class. ``interaction`` is set with
/// `GlassSurfaceView.beginInteraction()` and `endInteraction()`; the others
/// are the resting class (`GlassSurfaceView.motionClass`).
///
/// | Class | Frame rate range (Hz, minimum / preferred / maximum) |
/// |---|---|
/// | ``interaction`` | 80 / 120 / 120 |
/// | ``transition`` | the system default |
/// | ``ambient`` | 30 / 60 / 60 |
/// | ``slow`` | 15 / 30 / 30 |
///
/// The quality tier and the thermal state cap these (``frameRate(for:)``).
/// An iPhone above 60 Hz additionally needs the app's
/// `CADisableMinimumFrameDurationOnPhone` Info.plist key.
public enum GlassMotionClass: Hashable, Sendable, CaseIterable {
    /// Something calm that drifts: 15 to 30 Hz.
    case slow
    /// A pulse or a moving interior at rest: 30 to 60 Hz. The default.
    case ambient
    /// A short move between states: the system decides.
    case transition
    /// The user's finger is moving the glass or what is under it: 80 to 120 Hz.
    case interaction

    /// The frame rate range for this class at the tier and rate cap of
    /// `resolution`.
    public func frameRate(for resolution: GlassQualityResolution) -> GlassFrameRate {
        let quality = resolution.quality
        let maximumRate = resolution.maximumRate
        let base: GlassFrameRate
        let tierCap: Float
        switch self {
        case .interaction:
            base = GlassFrameRate(minimum: 80, preferred: 120, maximum: 120)
            tierCap = quality.interactionRate
        case .transition:
            base = .systemDefault
            tierCap = quality.effectClockRate
        case .ambient:
            base = GlassFrameRate(minimum: 30, preferred: 60, maximum: 60)
            tierCap = quality.effectClockRate
        case .slow:
            base = GlassFrameRate(minimum: 15, preferred: 30, maximum: 30)
            tierCap = quality.effectClockRate
        }
        return base.capped(at: min(tierCap, maximumRate ?? .infinity))
    }
}

/// A frame rate range in Hz, as `CAFrameRateRange` expresses one, without
/// importing QuartzCore into the core module.
///
/// **Experimental API** (GW-27).
public struct GlassFrameRate: Hashable, Sendable {
    public var minimum: Float
    public var preferred: Float
    public var maximum: Float

    public init(minimum: Float, preferred: Float, maximum: Float) {
        self.minimum = minimum
        self.preferred = preferred
        self.maximum = maximum
    }

    /// No preference: the system decides (`CAFrameRateRange.default`).
    public static let systemDefault = GlassFrameRate(minimum: 0, preferred: 0, maximum: 0)

    /// This range with no rate above `limit`. The system default has no
    /// rate to lower, so it stays as it is until the limit is below 120 Hz,
    /// when it becomes a range up to the limit.
    public func capped(at limit: Float) -> GlassFrameRate {
        if self == .systemDefault {
            guard limit < 120 else { return self }
            return GlassFrameRate(minimum: min(15, limit), preferred: limit, maximum: limit)
        }
        let maximum = min(self.maximum, limit)
        return GlassFrameRate(
            minimum: min(minimum, maximum), preferred: min(preferred, maximum), maximum: maximum
        )
    }
}
