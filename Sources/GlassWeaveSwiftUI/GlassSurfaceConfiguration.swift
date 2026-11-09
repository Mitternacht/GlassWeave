#if canImport(UIKit)
import GlassWeave
import GlassWeaveUIKit
import UIKit

/// What a ``GlassSurface`` shows behind its glass, and where the frames
/// come from.
///
/// A content is a reference type on purpose: SwiftUI compares it by
/// identity, so giving a surface the same content on every update changes
/// nothing, and giving it another one swaps the source. Either of two kinds:
///
/// - ``init(producer:)``: a frame producer (`GlassSurfaceView.FrameProducer`).
///   The UIKit host calls it inside each draw, on the main thread, never
///   during SwiftUI's body evaluation. The app's own clock decides when a new
///   frame is wanted and calls ``requestFrame()``.
/// - ``init(source:)``: one fixed frame, validated by the renderer when the
///   surface takes it. Use it for one surface at a time.
///
/// A content serves one surface at a time: when a surface is replaced (a new
/// `.id`), the new surface takes the content and the old one lets go of it.
///
/// > Important: Experimental. This API may change before a stable release.
@MainActor
public final class GlassSurfaceContent {
    private enum Supply {
        case source(BackgroundFrameLease)
        case producer(GlassSurfaceView.FrameProducer)
    }

    private let supply: Supply

    /// The surface showing this content now, or `nil`. A producer can ask it
    /// whether it already holds a frame (`renderer.currentFrame`) before it
    /// returns `nil` for "nothing changed", which a new surface, made by a new
    /// identity, does not.
    public private(set) weak var surface: GlassSurfaceView?

    /// A background drawn by `producer` inside every draw of the surface.
    /// See `GlassSurfaceView.setFrameProducer(_:)` for the producer's contract.
    public init(producer: @escaping GlassSurfaceView.FrameProducer) {
        supply = .producer(producer)
    }

    /// A background that is one existing frame, which the renderer validates.
    /// A frame the renderer rejects is reported through the surface's
    /// `onFailure` and the previous source stays.
    public init(source lease: BackgroundFrameLease) {
        supply = .source(lease)
    }

    /// Asks the surface showing this content for one new frame, like
    /// `GlassSurfaceView.requestFrame()`. Requests coalesce, and a surface that
    /// is not visible keeps one frame pending. Does nothing while no surface
    /// shows the content.
    public func requestFrame() {
        surface?.requestFrame()
    }

    /// Gives the content to `surface`.
    func attach(to surface: GlassSurfaceView) throws(BackgroundSourceError) {
        self.surface = surface
        switch supply {
        case let .source(lease): try surface.setSource(lease)
        case let .producer(producer): surface.setFrameProducer(producer)
        }
    }

    /// Takes the content back from `surface`, which then shows its opaque
    /// fallback until it gets another one.
    func detach(from surface: GlassSurfaceView) {
        if self.surface === surface { self.surface = nil }
        surface.setFrameProducer(nil)
        surface.clearSource()
    }
}

/// The low-frequency configuration of a ``GlassSurface``: values that change
/// when a person changes a setting or the layout changes, not once per frame.
///
/// The surface applies a configuration only when it is not equal to the one it
/// applied last, and then only the fields that differ. Per-frame work does not
/// belong here: put it in the ``GlassSurfaceContent`` producer, which runs in
/// the UIKit host. Panel frames are in the surface's own points: origin at its
/// top-left corner, as for `GlassSurfaceView.setPanels(_:)`.
///
/// > Important: Experimental. This API may change before a stable release.
public struct GlassSurfaceConfiguration: Equatable {
    /// The glass panels, in drawing order. Each follows the `GlassParameters`
    /// normalization rule when the surface takes it: a non-finite value is
    /// refused and reported through `onFailure`, a finite one is clamped.
    public var panels: [GlassPanel]
    /// The quality tier the app asks for; see `GlassQuality`.
    public var quality: GlassQuality
    /// The pacing hint for the surface's effect clock; see `GlassMotionClass`.
    public var motionClass: GlassMotionClass
    /// Where the Reduce Transparency and Reduce Motion settings come from:
    /// `.system` (the default) follows the device; `.fixed` overrides them,
    /// for previews and comparison runs.
    public var accessibilitySettings: GlassSurfaceView.AccessibilitySettingsSource
    /// Where Low Power Mode and the thermal state come from: `.fixed(.nominal)`
    /// by default (nothing is downgraded); `.system` follows the device.
    public var qualityEnvironment: GlassSurfaceView.QualityEnvironmentSource
    /// The background and its frames, or `nil` for none: the surface then shows
    /// its opaque fallback.
    public var content: GlassSurfaceContent?

    public init(
        panels: [GlassPanel] = [],
        quality: GlassQuality = .full,
        motionClass: GlassMotionClass = .ambient,
        accessibilitySettings: GlassSurfaceView.AccessibilitySettingsSource = .system,
        qualityEnvironment: GlassSurfaceView.QualityEnvironmentSource = .fixed(.nominal),
        content: GlassSurfaceContent? = nil
    ) {
        self.panels = panels
        self.quality = quality
        self.motionClass = motionClass
        self.accessibilitySettings = accessibilitySettings
        self.qualityEnvironment = qualityEnvironment
        self.content = content
    }

    /// Equal when every field is equal; the contents by identity.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.content === rhs.content
            && lhs.quality == rhs.quality
            && lhs.motionClass == rhs.motionClass
            && lhs.accessibilitySettings == rhs.accessibilitySettings
            && lhs.qualityEnvironment == rhs.qualityEnvironment
            && lhs.panels == rhs.panels
    }
}
#endif
