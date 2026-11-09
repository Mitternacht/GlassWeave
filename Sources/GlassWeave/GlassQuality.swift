import Foundation

/// How much a surface spends on its extras: a fixed, app-chosen reduction.
///
/// **Experimental API** (GW-27): the names and the table below can change.
///
/// A tier is a fixed set of reductions, not a governor. Nothing measures frame
/// time and moves the tier by itself, because a loop that trades quality for
/// refresh rate oscillates. The app picks the tier; Low Power Mode and the
/// thermal state can only lower what the app picked (``GlassQualityResolution``),
/// and ``GlassSurfaceView`` applies those changes between interactions. The
/// accessibility policy (`GlassAccessibilityPolicy`) is applied after the
/// tier, so Reduce Transparency and Increase Contrast draw their opaque body
/// at every tier and Reduce Motion stills whatever the tier left moving.
///
/// | | ``full`` | ``balanced`` | ``minimal`` |
/// |---|---|---|---|
/// | Effect clock rate | 60 Hz | 60 Hz | 30 Hz |
/// | Interaction rate | 120 Hz | 60 Hz | 60 Hz |
/// | Interior speed | as set | at most 1 | 0 (a still frame) |
/// | Fill (GW-28) | as set | at most 2 sheets and 8 bubbles | flat: no sheets, no bubbles, no waves |
///
/// Features that GlassWeave does not have yet are tier *hooks* and are not
/// implemented: the planned frost levels, dispersion taps, lighting model and
/// light emitters each get a row in this table when they land (see
/// `docs/presentation.md`). Only what exists is reduced now: the rates the
/// effect clock asks the display for, the glow interiors, and the liquid fill
/// (GW-28).
public enum GlassQuality: Int, CaseIterable, Comparable, Hashable, Sendable {
    /// Everything the panel asks for, at the rates the display allows.
    case minimal = 0
    /// Calmer interiors and no rate above 60 Hz.
    case balanced = 1
    /// Everything the panel asks for, with interaction frames up to 120 Hz.
    case full = 2

    public static func < (lhs: GlassQuality, rhs: GlassQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The most frames per second the effect clock (a pulse or a moving
    /// interior) asks the display for at this tier.
    public var effectClockRate: Float {
        switch self {
        case .full, .balanced: 60
        case .minimal: 30
        }
    }

    /// The most frames per second an interaction asks the display for at
    /// this tier.
    public var interactionRate: Float {
        switch self {
        case .full: 120
        case .balanced, .minimal: 60
        }
    }

    /// The interior to draw at this tier for `interior`: unchanged at
    /// ``full``, speed at most 1 at ``balanced``, a still frame (speed 0) at
    /// ``minimal``. An interior that draws nothing or does not move is kept
    /// as it is.
    public func reduced(_ interior: GlassInterior) -> GlassInterior {
        guard interior.isAnimated else { return interior }
        var reduced = interior
        switch self {
        case .full: break
        case .balanced: reduced.speed = min(interior.speed, 1)
        case .minimal: reduced.speed = 0
        }
        return reduced
    }

    /// The fill to draw at this tier for `fill` (GW-28): unchanged at
    /// ``full``, at most 2 sheets and 8 bubbles at ``balanced``, a flat fill
    /// with no sheets, no bubbles and still waves at ``minimal``. A fill that
    /// draws nothing is kept as it is.
    public func reduced(_ fill: GlassFill) -> GlassFill {
        guard fill.isActive else { return fill }
        var reduced = fill
        switch self {
        case .full: break
        case .balanced:
            reduced.sheets.count = min(fill.sheets.count, 2)
            reduced.bubbles.count = min(fill.bubbles.count, 8)
        case .minimal:
            reduced.sheets.count = 0
            reduced.bubbles.count = 0
            reduced.surface.waveAmplitude = 0
        }
        return reduced
    }

    /// `panel` as drawn at this tier (before the accessibility policy).
    public func reduced(_ panel: GlassPanel) -> GlassPanel {
        guard self != .full else { return panel }
        var reduced = panel
        reduced.parameters.interior = self.reduced(panel.parameters.interior)
        reduced.parameters.fill = self.reduced(panel.parameters.fill)
        return reduced
    }
}

/// What the system says about power and heat, for choosing a tier.
///
/// **Experimental API** (GW-27).
public struct GlassQualityEnvironment: Hashable, Sendable {
    /// Low Power Mode is on.
    public var isLowPowerModeEnabled: Bool
    /// The device's thermal state.
    public var thermalState: ProcessInfo.ThermalState

    public init(isLowPowerModeEnabled: Bool = false, thermalState: ProcessInfo.ThermalState = .nominal) {
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalState = thermalState
    }

    /// Plenty of power and no heat.
    public static let nominal = GlassQualityEnvironment()

    /// The values the system reports now.
    public static var system: GlassQualityEnvironment {
        GlassQualityEnvironment(
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }
}

/// The tier a surface draws at once the environment has had its say.
///
/// **Experimental API** (GW-27).
///
/// | Environment | Result |
/// |---|---|
/// | Nominal or fair | the requested tier |
/// | Low Power Mode | at most ``GlassQuality/balanced`` (the system also lowers the refresh rate) |
/// | Serious thermal state | ``GlassQuality/minimal`` |
/// | Critical thermal state | ``GlassQuality/minimal`` and no rate above 30 Hz |
///
/// The environment never raises the tier above the one requested.
public struct GlassQualityResolution: Hashable, Sendable {
    /// The tier to draw at.
    public private(set) var quality: GlassQuality
    /// A rate cap in Hz that applies to every motion class, or `nil`. Only
    /// the thermal state sets it, so it is always finite.
    public private(set) var maximumRate: Float?

    public init(requested: GlassQuality, environment: GlassQualityEnvironment) {
        var quality = requested
        var maximumRate: Float?
        if environment.isLowPowerModeEnabled {
            quality = min(quality, .balanced)
        }
        switch environment.thermalState {
        case .serious:
            quality = .minimal
        case .critical:
            quality = .minimal
            maximumRate = 30
        case .nominal, .fair:
            break
        @unknown default:
            break
        }
        self.quality = quality
        self.maximumRate = maximumRate
    }
}
