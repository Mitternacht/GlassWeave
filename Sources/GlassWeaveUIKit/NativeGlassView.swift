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
    /// The public `UIGlassEffect` settings GlassWeave exposes.
    public struct Configuration: Equatable {
        /// The glass tint, or `nil` for untinted glass.
        public var tintColor: UIColor?
        /// Whether the glass reacts to touches (`UIGlassEffect.isInteractive`).
        public var isInteractive: Bool

        public init(tintColor: UIColor? = nil, isInteractive: Bool = false) {
            self.tintColor = tintColor
            self.isInteractive = isInteractive
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
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = configuration.tintColor
        effect.isInteractive = configuration.isInteractive
        return effect
    }
}
#endif
