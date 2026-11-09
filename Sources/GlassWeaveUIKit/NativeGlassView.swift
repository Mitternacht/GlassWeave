#if canImport(UIKit)
import UIKit

/// Native mode: Apple's own glass material around native content.
///
/// A `UIVisualEffectView` whose effect is a public `UIGlassEffect` built from
/// ``configuration``. Place controls in `contentView`, as with any visual
/// effect view; they stay ordinary UIKit controls with their own hit
/// testing, focus, and accessibility. Shape the glass with the view's
/// `cornerConfiguration`. The system draws the material from its own
/// backdrop; GlassWeave adds no optics to it.
///
/// Native mode creates no GlassWeave renderer, Metal device, command queue,
/// `MTKView`, or display loop. That is checked by test, through the
/// renderer census that every GlassWeave renderer reports to.
///
/// Change the glass through ``configuration``; assigning `effect` directly
/// bypasses it and is overwritten by the next configuration change.
@MainActor
public final class NativeGlassView: UIVisualEffectView {
    /// The two public `UIGlassEffect` styles.
    ///
    /// > Important: Experimental. This API may change before a stable release.
    public enum Style: Equatable, Sendable {
        /// `UIGlassEffect.Style.regular`: the standard material. It blurs and
        /// adjusts the luminosity of what lies behind it so text on it stays
        /// legible. The default.
        case regular
        /// `UIGlassEffect.Style.clear`: a highly translucent variant that lets
        /// the detail behind it show through, meant for controls that float
        /// over rich backgrounds such as photos and video.
        ///
        /// Apple's documentation says to keep content legible over clear glass
        /// with a **dimming layer** (or another treatment) behind it: over
        /// bright content, consider a dark layer of about 35% opacity; over
        /// sufficiently dark content none is needed. This view draws no
        /// dimming layer. Adding one is the app's job: place a black view at
        /// about that opacity **behind** the glass (not in `contentView`,
        /// where it would dim the glass's own content). The system may also
        /// render either style differently under Reduce Transparency,
        /// Increase Contrast, or the person's Liquid Glass look setting.
        case clear
    }

    /// The public `UIGlassEffect` settings GlassWeave exposes.
    public struct Configuration: Equatable {
        /// The glass tint, or `nil` for untinted glass.
        public var tintColor: UIColor?
        /// Whether the glass reacts to touches (`UIGlassEffect.isInteractive`).
        public var isInteractive: Bool
        /// The glass style (`UIGlassEffect.Style`); ``Style/regular`` unless
        /// asked for. See ``Style/clear`` for Apple's dimming-layer note.
        public var style: Style

        public init(tintColor: UIColor? = nil, isInteractive: Bool = false, style: Style = .regular) {
            self.tintColor = tintColor
            self.isInteractive = isInteractive
            self.style = style
        }
    }

    /// The current glass settings. Setting a different value replaces the
    /// effect; call it inside an animation block to animate the change.
    public var configuration: Configuration {
        didSet {
            if configuration != oldValue {
                effect = Self.makeEffect(configuration)
            }
        }
    }

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        super.init(effect: Self.makeEffect(configuration))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func makeEffect(_ configuration: Configuration) -> UIGlassEffect {
        let effect = UIGlassEffect(style: configuration.style == .clear ? .clear : .regular)
        effect.tintColor = configuration.tintColor
        effect.isInteractive = configuration.isInteractive
        return effect
    }
}
#endif
