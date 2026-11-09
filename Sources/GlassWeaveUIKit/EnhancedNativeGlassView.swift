#if canImport(UIKit)
import GlassWeave
import UIKit

/// Enhanced-native mode: genuine Apple glass with a colored rim and halo
/// that Core Animation composites around it.
///
/// The view holds a ``NativeGlassView`` (``glass``) that fills its bounds:
/// a `UIVisualEffectView` with a public `UIGlassEffect`. Apple's glass keeps
/// its material, its backdrop, and its own tint (``NativeGlassView/configuration``);
/// GlassWeave never recolors the inside of it. Around it, layers draw the
/// rim and halo of a `GlassGlow` in one color or an angular gradient of up
/// to four stops, the same color model as a custom panel's glow, so one
/// value can style both modes:
///
/// | `GlassGlow` field | In native mode |
/// | --- | --- |
/// | `colors`, `lightAngle`, `directionality` | As in custom mode: the gradient around the center (the shape scaled to a square, 0° at the top, clockwise), interpolated in linear light, and the light of the outline point on each ray from the center. Sampled every 2° into conic gradients. |
/// | `rimWidth`, `rimSoftness`, `rimIntensity` | A band `rimWidth` deep just inside the outline, over the glass's edge, fully opaque (times `rimIntensity` and the light). With a softness `s` its inner edge then fades over about `s` (half intensity at `rimWidth + s/2`, from a Core Animation shadow of `s/4`); with `s = 0` it is crisp. Both lengths are limited to half the shorter side of the bounds. |
/// | `haloRadius`, `haloIntensity` | A halo outside the outline only: a Core Animation shadow (Gaussian) of the outline, about 95 % of `haloIntensity` at a straight edge, 25 % at half the radius, and below 0.2 % at the radius. |
/// | `pulsePeriod`, `pulseDepth` | A Core Animation opacity animation of the rim and halo with custom mode's level, `1 − pulseDepth × (1 − cos 2πt/period) / 2`, while the view is visible. |
/// | `innerGlowRadius`, `innerGlowIntensity`, `centerOpacity` | Not drawn: the inside is Apple's material. ``presentedGlow`` reports them as 0. |
///
/// Core Animation composites the rim and halo source-over, in the window's
/// color space, as it does every layer; GlassWeave chooses their colors in
/// linear light but not the blend. A halo shows best on darker backgrounds:
/// over a light background a color darkens the channels it lacks.
///
/// **Layout.** Lay this view out where the glass should be, and put
/// controls in `glass.contentView`; shape the glass with
/// `glass.cornerConfiguration` (fixed, per-corner, capsule, or
/// container-concentric radii are read with `effectiveRadius(corner:)` at
/// every layout pass, so the glow follows them). The view does not clip:
/// the halo reaches about `haloRadius` (its layers about 1.2 × `haloRadius`)
/// outside the bounds, so keep that margin free and unclipped by ancestors
/// (a scroll view or a view with `clipsToBounds` cuts it off) and leave
/// `glass.contentView.clipsToBounds` off. When the glass's frame is
/// animated (a `UIView` animation, rotation), the glow's paths animate with
/// the glass's own timing.
///
/// **Where the glow lives.** The rim and halo are sublayers of one host
/// layer in `glass.contentView`'s layer, sized to the content view and drawn
/// above the app's content there (`zPosition` 1). Interactive glass
/// (`NativeGlassView.Configuration.isInteractive`) grows while it is pressed
/// and scales its content with it; hosted in the content, the rim stays on
/// the glass's edge and the halo outside it for as long as the press lasts.
/// They are layers, not views: `glass.contentView.subviews` stays the app's
/// own, and they take no touches and add no accessibility element, so hit
/// testing and VoiceOver reach the glass's content exactly as without them.
/// The halo is drawn over Apple's material outside its outline only, so the
/// glass neither covers nor samples it.
///
/// **No custom rendering.** The view creates no GlassWeave renderer, Metal
/// device, command queue, `MTKView`, display link, or update link. A settled
/// glow (no pulse, or Reduce Motion) runs no animation; a pulse is one
/// Core Animation animation per layer, attached only while the view is in a
/// window, neither it nor an ancestor is hidden or transparent, and its own
/// window scene is in the foreground. The view looks again when it moves to
/// a window, its own `isHidden` or `alpha` changes, its scene changes state,
/// and at every layout pass; UIKit reports no change to an ancestor's
/// `isHidden` or `alpha`, so after hiding an ancestor call `setNeedsLayout()`
/// and `layoutIfNeeded()` on this view to remove the pulse at once. The pulse
/// resumes where it stopped.
///
/// **Accessibility** follows ``GlassAccessibilityPolicy`` (the glow rows):
/// Reduce Transparency keeps only a crisp, evenly lit rim at most
/// ``GlassAccessibilityPolicy/reducedTransparencyRimWidth`` wide, with no
/// halo or pulse; Increase Contrast keeps the rim, evenly lit, and the halo
/// and pulse; Reduce Motion holds the rim and halo at the pulse's mean level
/// with no animation. The glass applies the system's own settings to its
/// material.
///
/// **Colors** are sRGB components; to follow light and dark appearance with
/// dynamic colors, set the glow again from `registerForTraitChanges` with
/// stops from `GlassGlow.ColorStop(_:angle:traits:)`.
@MainActor
public final class EnhancedNativeGlassView: UIView {
    /// The genuine glass. Configure it through its
    /// ``NativeGlassView/configuration`` and `cornerConfiguration`, and put
    /// controls in its `contentView`.
    public let glass: NativeGlassView

    /// The glow the app set, after the normalization rule (lengths are not
    /// yet limited by the bounds); `GlassGlow.none` draws nothing.
    public private(set) var glow: GlassGlow = .none

    /// The glow drawn: ``glow`` after ``GlassAccessibilityPolicy`` for the
    /// current ``accessibilitySettings`` and traits, without the parts
    /// native mode does not draw (inner glow and center fill are 0), and
    /// with the rim's lengths limited to half the shorter side of the
    /// current bounds.
    public private(set) var presentedGlow: GlassGlow = .none

    /// Where ``accessibilitySettings`` come from. Setting it applies the new
    /// settings at once.
    public var accessibilitySettingsSource: GlassSurfaceView.AccessibilitySettingsSource = .system {
        didSet { refreshAccessibilitySettings() }
    }

    /// The settings currently applied.
    public private(set) var accessibilitySettings = GlassAccessibilitySettings()

    /// Whether the pulse animation is attached: the presented glow pulses
    /// and the view is visible.
    public var isAnimating: Bool {
        runningPulse != nil
    }

    /// What the layers draw for the current layout.
    private(set) var layout = NativeGlowLayout(size: .zero, radii: .zero, displayScale: 1, glow: .none)

    // The halo, outside the outline: a conic gradient seen through a shadow
    // of the outline, inside a layer whose mask removes the glass's interior.
    let haloLayer = CALayer()
    let haloHoleMask = CAShapeLayer()
    let haloGradient = CAGradientLayer()
    let haloShadowMask = CALayer()
    // The rim, over the glass's edge: a conic gradient seen through the
    // band, inside a layer clipped to the outline.
    let rimLayer = CALayer()
    let rimClipMask = CAShapeLayer()
    let rimGradient = CAGradientLayer()
    let rimBandMask = CAShapeLayer()
    /// Holds ``haloLayer`` and ``rimLayer`` in `glass.contentView`'s layer,
    /// at its bounds, so whatever the glass does to its content (the growth
    /// of interactive glass while pressed) applies to the glow too.
    let glowHost = CALayer()
    /// The host's `zPosition`: above the app's content in the glass, as the
    /// rim is the shape's outline.
    static let glowHostZPosition: CGFloat = 1

    /// Every layer the glow adds.
    var glowLayers: [CALayer] {
        [glowHost, haloLayer, haloHoleMask, haloGradient, haloShadowMask, rimLayer, rimClipMask, rimGradient, rimBandMask]
    }

    /// The key of the pulse animation on ``haloLayer`` and ``rimLayer``.
    static let pulseAnimationKey = "dev.glassweave.pulse"
    /// The prefix of the keys of animations that follow the glass's frame.
    static let layoutAnimationKeyPrefix = "dev.glassweave.layout."

    /// The running pulse: its period and depth, and the media time of its
    /// phase 0.
    private var runningPulse: (period: Double, depth: Double, origin: CFTimeInterval)?
    /// Where in its period (0..<1) the pulse stopped, so it resumes there.
    private var pulsePhase = 0.0

    /// Whether the view is visible by the ``GlassSurfaceView`` rule.
    private(set) var isVisible = false

    /// Stands in for the window and window scene, for tests (as
    /// `GlassSurfaceView.sceneStateOverride`).
    var sceneStateOverride: SurfaceVisibility.SceneState? {
        didSet { refreshVisibility() }
    }

    private weak var observedScene: UIWindowScene?
    private var sceneObservations: [NotificationCenter.ObservationToken] = []

    public init(configuration: NativeGlassView.Configuration = NativeGlassView.Configuration()) {
        glass = NativeGlassView(configuration: configuration)
        super.init(frame: .zero)
        clipsToBounds = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for gradient in [haloGradient, rimGradient] {
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
        }
        haloShadowMask.shadowColor = UIColor.black.cgColor
        haloShadowMask.shadowOpacity = 1
        haloShadowMask.shadowOffset = .zero
        haloGradient.mask = haloShadowMask
        haloHoleMask.fillColor = UIColor.black.cgColor
        haloHoleMask.fillRule = .nonZero
        haloLayer.addSublayer(haloGradient)
        haloLayer.mask = haloHoleMask

        rimBandMask.fillRule = .nonZero
        rimBandMask.fillColor = UIColor.black.cgColor
        rimBandMask.shadowColor = UIColor.black.cgColor
        rimBandMask.shadowOffset = .zero
        rimGradient.mask = rimBandMask
        rimClipMask.fillColor = UIColor.black.cgColor
        rimLayer.addSublayer(rimGradient)
        rimLayer.mask = rimClipMask

        haloLayer.isHidden = true
        rimLayer.isHidden = true
        glowHost.masksToBounds = false
        glowHost.zPosition = Self.glowHostZPosition
        glowHost.addSublayer(haloLayer)
        glowHost.addSublayer(rimLayer)
        glass.contentView.layer.addSublayer(glowHost)

        registerForTraitChanges([UITraitDisplayScale.self, UITraitAccessibilityContrast.self]) { (self: Self, _) in
            self.updateGlow()
        }
        let center = NotificationCenter.default
        for name in [
            UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            UIAccessibility.reduceMotionStatusDidChangeNotification,
        ] {
            center.addObserver(self, selector: #selector(systemAccessibilitySettingsChanged), name: name, object: nil)
        }
        refreshAccessibilitySettings()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Sets the glow and redraws the rim and halo. A non-finite value
    /// throws `GlassParameterError.nonFinite(_:)` naming its field and
    /// leaves the current glow in place; finite values out of range are
    /// clamped by the `GlassGlow` normalization rule.
    public func setGlow(_ glow: GlassGlow) throws(GlassParameterError) {
        self.glow = try glow.normalized(maximumLength: .infinity)
        updateGlow()
    }

    // MARK: Presentation

    /// The parts of `glow` native mode draws, with the rim's lengths limited
    /// to half the shorter side of `size`.
    static func nativeGlow(_ glow: GlassGlow, size: CGSize) -> GlassGlow {
        guard !glow.colors.isEmpty else { return .none }
        let limit = max(Double(min(size.width, size.height)) / 2, 0)
        var native = glow
        native.rimWidth = min(glow.rimWidth, limit)
        native.rimSoftness = min(glow.rimSoftness, limit)
        native.innerGlowRadius = 0
        native.innerGlowIntensity = 0
        native.centerOpacity = 0
        return native
    }

    /// The glass's corner radii as it resolves them now. Read during
    /// `layoutSubviews`, a change of the effective radii lays the view out
    /// again (UIKit's automatic invalidation).
    private var cornerRadii: NativeGlowLayout.CornerRadii {
        NativeGlowLayout.CornerRadii(
            topLeft: glass.effectiveRadius(corner: .topLeft),
            topRight: glass.effectiveRadius(corner: .topRight),
            bottomRight: glass.effectiveRadius(corner: .bottomRight),
            bottomLeft: glass.effectiveRadius(corner: .bottomLeft)
        )
    }

    /// Recomputes the presented glow and the layers for the current
    /// geometry, traits, and settings. With `template` (the glass's running
    /// frame animation) the layers' geometry animates the same way.
    private func updateGlow(like template: CAAnimation? = nil) {
        // The layers live in the glass's content, whose origin is the
        // glass's own.
        let size = glass.bounds.size
        let presented = Self.nativeGlow(
            GlassAccessibilityPolicy.presentedGlow(for: glow, settings: accessibilitySettings, traits: traitCollection),
            size: size
        )
        presentedGlow = presented
        let radii = cornerRadii
        let scale = traitCollection.displayScale
        // Most layout passes change nothing the glow depends on.
        if size == layout.size, radii.clamped(to: size) == layout.radii,
           scale == layout.displayScale, presented == layout.glow {
            updatePulse()
            return
        }
        let newLayout = NativeGlowLayout(size: size, radii: radii, displayScale: scale, glow: presented)
        apply(newLayout, like: template)
        layout = newLayout
        layoutBuilds += 1
        updatePulse()
    }

    /// How many times the layers were rebuilt, for tests.
    private(set) var layoutBuilds = 0

    override public func layoutSubviews() {
        super.layoutSubviews()
        // The glass resolves its corners (a capsule's radius follows its
        // height) in its own layout pass; run it first so the radii read
        // below belong to the frame just set.
        glass.layoutIfNeeded()
        let template = glass.layer.animation(forKey: "bounds.size") ?? glass.layer.animation(forKey: "bounds")
        updateGlow(like: template)
        refreshVisibility()
    }

    // MARK: Layers

    private func apply(_ layout: NativeGlowLayout, like template: CAAnimation?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for glowLayer in glowLayers where glowLayer.contentsScale != layout.displayScale {
            glowLayer.contentsScale = layout.displayScale
        }
        let animator = LayerAnimator(template: template)
        // The host fills the content view, which fills the glass.
        animator.set(glowHost, frame: CGRect(origin: .zero, size: layout.size))

        if let rim = layout.rim {
            rimLayer.isHidden = false
            let local = CGRect(origin: .zero, size: layout.size)
            animator.set(rimLayer, frame: local)
            for sublayer in [rimClipMask, rimGradient, rimBandMask] as [CALayer] {
                animator.set(sublayer, frame: local)
            }
            animator.set(rimClipMask, path: rim.clipPath)
            animator.set(rimBandMask, path: rim.bandPath)
            rimGradient.colors = rim.gradient.cgColors
            rimGradient.locations = rim.gradient.locations.map { NSNumber(value: $0) }
            if rim.softnessRadius > 0 {
                // The crisp band over the shadow of the extended band.
                animator.set(rimBandMask, shadowPath: rim.softBandPath)
                rimBandMask.shadowRadius = rim.softnessRadius
                rimBandMask.shadowOpacity = 1
            } else {
                rimBandMask.shadowOpacity = 0
                rimBandMask.shadowPath = nil
            }
        } else {
            rimLayer.isHidden = true
        }

        if let halo = layout.halo {
            haloLayer.isHidden = false
            let local = CGRect(origin: .zero, size: halo.frame.size)
            animator.set(haloLayer, frame: halo.frame)
            for sublayer in [haloHoleMask, haloGradient, haloShadowMask] as [CALayer] {
                animator.set(sublayer, frame: local)
            }
            animator.set(haloHoleMask, path: halo.holePath)
            animator.set(haloShadowMask, shadowPath: halo.shadowPath)
            haloShadowMask.shadowRadius = halo.shadowRadius
            haloGradient.colors = halo.gradient.cgColors
            haloGradient.locations = halo.gradient.locations.map { NSNumber(value: $0) }
        } else {
            haloLayer.isHidden = true
        }
    }

    /// Sets layer geometry, animating each change like the glass's own frame
    /// animation when there is one.
    @MainActor
    private struct LayerAnimator {
        let template: CAAnimation?

        func set(_ layer: CALayer, frame: CGRect) {
            let bounds = CGRect(origin: .zero, size: frame.size)
            let position = CGPoint(x: frame.midX, y: frame.midY)
            animate(layer, "bounds", from: NSValue(cgRect: layer.bounds), to: NSValue(cgRect: bounds), changed: layer.bounds != bounds)
            animate(layer, "position", from: NSValue(cgPoint: layer.position), to: NSValue(cgPoint: position), changed: layer.position != position)
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.bounds = bounds
            layer.position = position
        }

        func set(_ layer: CAShapeLayer, path: CGPath) {
            animate(layer, "path", from: layer.path, to: path, changed: layer.path != path)
            layer.path = path
        }

        func set(_ layer: CALayer, shadowPath: CGPath) {
            animate(layer, "shadowPath", from: layer.shadowPath, to: shadowPath, changed: layer.shadowPath != shadowPath)
            layer.shadowPath = shadowPath
        }

        private func animate(_ layer: CALayer, _ keyPath: String, from: Any?, to: Any, changed: Bool) {
            guard changed, let template, let from else { return }
            let animation: CABasicAnimation
            if let spring = template as? CASpringAnimation {
                let matching = CASpringAnimation(keyPath: keyPath)
                matching.mass = spring.mass
                matching.stiffness = spring.stiffness
                matching.damping = spring.damping
                matching.initialVelocity = spring.initialVelocity
                animation = matching
            } else {
                animation = CABasicAnimation(keyPath: keyPath)
            }
            // From the value shown now (mid-animation, the presentation).
            animation.fromValue = layer.presentation()?.value(forKeyPath: keyPath) ?? from
            animation.toValue = to
            animation.duration = template.duration
            animation.beginTime = template.beginTime
            animation.timingFunction = template.timingFunction
            animation.speed = template.speed
            animation.fillMode = .backwards
            layer.add(animation, forKey: EnhancedNativeGlassView.layoutAnimationKeyPrefix + keyPath)
        }
    }

    // MARK: Pulse

    private var wantsPulse: Bool {
        isVisible && presentedGlow.isAnimated
    }

    /// Attaches, replaces, or removes the pulse animation to match
    /// ``wantsPulse`` and the presented pulse.
    private func updatePulse() {
        let period = presentedGlow.pulsePeriod, depth = presentedGlow.pulseDepth
        if let running = runningPulse {
            guard !wantsPulse || running.period != period || running.depth != depth else { return }
            pulsePhase = ((CACurrentMediaTime() - running.origin) / running.period).truncatingRemainder(dividingBy: 1)
            haloLayer.removeAnimation(forKey: Self.pulseAnimationKey)
            rimLayer.removeAnimation(forKey: Self.pulseAnimationKey)
            runningPulse = nil
        }
        guard wantsPulse else { return }
        // Half a period down and back up, eased like (1 − cos) / 2 (the
        // sine ease-in-out curve), so the level is custom mode's
        // 1 − depth × (1 − cos(2πt / period)) / 2.
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 1 - depth
        animation.duration = period / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.37, 0, 0.63, 1)
        animation.timeOffset = pulsePhase * period
        haloLayer.add(animation, forKey: Self.pulseAnimationKey)
        rimLayer.add(animation, forKey: Self.pulseAnimationKey)
        runningPulse = (period, depth, CACurrentMediaTime() - pulsePhase * period)
    }

    // MARK: Visibility and settings

    override public var isHidden: Bool {
        didSet { refreshVisibility() }
    }

    override public var alpha: CGFloat {
        didSet { refreshVisibility() }
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        observeScene(window?.windowScene)
        refreshVisibility()
    }

    private func refreshVisibility() {
        let sceneState = sceneStateOverride
            ?? window?.windowScene.map { SurfaceVisibility.SceneState($0.activationState) }
            ?? .none
        isVisible = SurfaceVisibility(
            isInWindow: sceneStateOverride != nil || window != nil,
            isHiddenInHierarchy: isHiddenInHierarchy,
            sceneState: sceneState
        ).isVisible
        updatePulse()
    }

    private var isHiddenInHierarchy: Bool {
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha <= 0.01 { return true }
            view = current.superview
        }
        return false
    }

    /// Observes the lifecycle of `scene` only, replacing any earlier
    /// observation.
    private func observeScene(_ scene: UIWindowScene?) {
        guard scene !== observedScene || (scene != nil && sceneObservations.isEmpty) else { return }
        observedScene = scene
        sceneObservations = []
        guard let scene else { return }
        let center = NotificationCenter.default
        let subject: UIScene = scene
        sceneObservations = [
            center.addObserver(of: subject, for: UIScene.WillEnterForegroundMessage.self) { [weak self] _ in
                // Posted before the state changes; look again once it has.
                self?.refreshVisibility()
                Task { @MainActor [weak self] in self?.refreshVisibility() }
            },
            center.addObserver(of: subject, for: UIScene.DidActivateMessage.self) { [weak self] _ in
                self?.refreshVisibility()
            },
            center.addObserver(of: subject, for: UIScene.WillDeactivateMessage.self) { [weak self] _ in
                self?.refreshVisibility()
            },
            center.addObserver(of: subject, for: UIScene.DidEnterBackgroundMessage.self) { [weak self] _ in
                self?.refreshVisibility()
            },
        ]
    }

    @objc private func systemAccessibilitySettingsChanged() {
        refreshAccessibilitySettings()
    }

    private func refreshAccessibilitySettings() {
        let settings: GlassAccessibilitySettings = switch accessibilitySettingsSource {
        case .system: .system
        case let .fixed(settings): settings
        }
        guard settings != accessibilitySettings else { return }
        accessibilitySettings = settings
        updateGlow()
    }
}
#endif
