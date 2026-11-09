#if canImport(UIKit)
import GlassWeave
import MetalKit
import UIKit

/// Presents an explicit background source, with rounded glass panels over
/// it, through an `MTKView`'s Metal layer, on demand.
///
/// The view draws only when something changes: a new source, new panels, a
/// new pixel size, a display-scale change, an app request through
/// ``requestFrame()``, or a tick of the view's effect clock while a glow or
/// interior animates. No other display loop runs; an app animating its
/// source drives redraws from its own clock and can produce each frame
/// inside the draw with ``setFrameProducer(_:)``. Panels are given in this
/// view's points and converted with the same display scale as the drawable:
/// one with ``setPanel(_:)``, or an ordered list of up to
/// `GlassRenderer.maximumPanelCount` with ``setPanels(_:)``, all drawn in one
/// pass over the same frame (see `GlassRenderer` for how their quads must
/// not overlap). The view sizes its drawable from its own bounds and
/// `traitCollection.displayScale`, never from a screen or a global scene.
///
/// Effect clock (``isAnimating``): while any presented panel whose
/// parameters animate (`GlassParameters.isAnimated`: a glow pulse, an
/// interior with a speed above 0, an animated inner light, or a wobbling
/// shape) can change a pixel of the
/// drawable (it has area, and its quad, the panel grown by one pixel and its
/// halo radius, overlaps the view's bounds), the view has a source or a
/// frame producer, and the view is visible, the view runs one `UIUpdateLink`
/// created for itself, so it follows its own window's display, and asks that
/// display for the frame rate range of its motion class (``motionClass``,
/// ``beginInteraction()``, ``quality``). Each update advances the effect time
/// by the update's model time and calls ``requestFrame()``, so ticks go through the same scheduler as
/// every other request: they coalesce, wait while hidden, and never exceed
/// the in-flight bound. Each draw evaluates the glow and the interior at the
/// effect time (`GlassRenderer.effectTime`). The link is removed as soon as
/// nothing animates any more (no pulse, no moving interior, light or shape,
/// or Reduce Motion, which steadies and stills all of them), every animated
/// panel lies outside the bounds or has no area, the source and the producer
/// are gone, the view stops being visible, or it leaves its window; the
/// effect time then stays where it was and continues from there when the
/// clock runs again. The view looks again whenever its panels, bounds,
/// display scale, source, producer, settings, or visibility change.
///
/// Scheduling (``frameStatistics`` reports each step):
/// - Requests made before the next display pass merge into one draw.
/// - The view draws only while it is visible: in a window, not hidden (nor
///   any ancestor), with an alpha above zero, and with its *own* window
///   scene in the foreground (active or inactive). It observes that scene
///   only, so a hidden or backgrounded surface never pauses a visible
///   surface in another scene. Requests while not visible leave one pending
///   frame, drawn when the view is visible again.
/// - At most ``maximumFramesInFlight`` frames are committed and not yet
///   completed. A draw at that bound is deferred, never queued or waited
///   for; the pending frame is drawn when a frame completes.
/// - Leaving the visible state stops drawing but frees nothing: the Metal
///   layer keeps its drawables (up to three at the drawable size). The app
///   can give back its own memory from ``visibilityHandler``, for example by
///   trimming its texture pool. Every texture a submitted frame uses stays
///   alive until that frame completes, and no path waits for the GPU.
///
/// Drawables (GW-27): the view never waits for one on the main thread. When a
/// frame is pending and can be drawn, a background queue takes the drawable
/// from the Metal layer (`CAMetalLayer.nextDrawable()` waits there, up to the
/// layer's one-second timeout), the draw runs on the main thread when it
/// arrives, and a drawable that is no longer wanted is released. If the wait
/// times out the view counts it (``drawableTimeouts``) and asks again shortly,
/// so a request made while every drawable is held elsewhere draws as soon as
/// one is free, and the main thread, its run loop and its animations keep
/// running meanwhile. The producer and the observer run on the main thread as
/// before.
///
/// Defined skips. None waits for GPU work; the first two return before a
/// drawable is requested:
/// - No source: the Metal view is hidden and the opaque `backgroundColor`
///   shows as the fallback. ``lastRenderOutcome`` is
///   `.skipped(.missingSource)`.
/// - Zero-size bounds or a zero display scale: no drawable is requested and
///   the outcome is `.skipped(.zeroSizeTarget)`.
/// - No drawable available: the outcome is `.skipped(.drawableUnavailable)`
///   and the producer's lease counts the skipped use. The view's own draws
///   no longer reach this skip: they start only once a drawable is in hand
///   (a timed-out wait is retried, not skipped, and is counted in
///   ``drawableTimeouts``), so the pending frame is kept and the producer is
///   not asked for a frame it could not present. Only the synchronous test
///   path (`renderNow()`), which asks the layer on the calling thread, can
///   still skip here.
///
/// The surface is decorative: neither it nor its Metal view is an
/// accessibility element (its accessibility elements are hidden), and it
/// does not take touches, so native content placed above it keeps its
/// behavior and VoiceOver reaches only that content. An app that wants the
/// glass to answer a finger (GW-12, ``GlassTouch``) attaches a
/// ``GlassTouchObserver`` to the stage or any ancestor view; it forwards the
/// touches through ``beginTouch(id:at:)`` and the methods after it without
/// changing how any native control behaves.
///
/// Accessibility settings (``accessibilitySettings``) change what is drawn
/// as ``GlassAccessibilityPolicy`` documents: under Reduce Transparency the
/// panel becomes an opaque surface (``presentedPanel``), and under Reduce
/// Motion a pulsing glow is drawn steady at its mean level and an interior
/// as its still frame, so the effect clock stops. By default the view follows the system settings and their
/// change notifications.
@MainActor
public final class GlassSurfaceView: UIView {
    public let renderer: GlassRenderer

    /// The result of the most recent draw request, for diagnostics.
    public private(set) var lastRenderOutcome: BackgroundRenderOutcome?

    /// Called after every draw request with its outcome.
    public var renderObserver: ((BackgroundRenderOutcome) -> Void)?

    /// Encodes a new source frame into the draw's command buffer and returns
    /// its lease, or `nil` to produce nothing this time. See
    /// `GlassRenderer.drawProducing(targetPixelSize:displayScale:produce:acquireTarget:)`
    /// in GlassWeave.
    public typealias FrameProducer = (
        _ commandBuffer: any MTLCommandBuffer,
        _ pixelSize: (width: Int, height: Int)
    ) -> BackgroundFrameLease?

    /// The source-contract error of the last produced frame the renderer
    /// rejected, or `nil` once a produced frame is accepted.
    public private(set) var lastProducedFrameError: BackgroundSourceError?

    private var frameProducer: FrameProducer?

    /// The render target size in pixels: bounds times display scale, rounded
    /// to whole pixels. Zero in a dimension when the view has no area.
    public private(set) var pixelSize: (width: Int, height: Int) = (0, 0)

    /// The most frames this view keeps committed and not yet completed.
    public static let maximumFramesInFlight = FrameScheduler.defaultMaxFramesInFlight

    /// What the scheduler has done: requests, coalesced requests, submitted
    /// and completed frames, deferrals, and frames in flight.
    public var frameStatistics: FrameStatistics {
        scheduler.statistics
    }

    /// How many times the layer's drawable wait ran out (its one-second
    /// timeout) while a frame was pending. The wait happens on a background
    /// queue and the view asks again, so it never stalls the main thread; a
    /// count that keeps rising means something else holds the layer's
    /// drawables.
    public private(set) var drawableTimeouts = 0

    /// Whether the view currently draws: in a window, not hidden, and with its
    /// window scene in the foreground.
    public private(set) var isVisible = false

    /// Called when ``isVisible`` changes, for example to trim a producer's
    /// texture pool while the view is hidden.
    public var visibilityHandler: ((Bool) -> Void)?

    /// Where the view reads its accessibility settings.
    public enum AccessibilitySettingsSource: Hashable, Sendable {
        /// `UIAccessibility`, updated when the system posts a change.
        case system
        /// Fixed values, for tests, previews, and comparison runs.
        case fixed(GlassAccessibilitySettings)
    }

    /// Where ``accessibilitySettings`` come from. Setting it applies the new
    /// settings at once.
    public var accessibilitySettingsSource: AccessibilitySettingsSource = .system {
        didSet { refreshAccessibilitySettings() }
    }

    /// The settings currently applied.
    public private(set) var accessibilitySettings = GlassAccessibilitySettings()

    /// Called when ``accessibilitySettings`` change, for example so the app
    /// can stop its source's nonessential motion under Reduce Motion.
    public var accessibilitySettingsHandler: ((GlassAccessibilitySettings) -> Void)?

    /// Whether the effect clock runs: a presented panel's parameters animate
    /// (a glow pulse, an interior with a speed above 0, an animated inner
    /// light, or a wobbling shape, none of them steadied or stilled by Reduce
    /// Motion) and that
    /// panel can change a pixel of the drawable, the view has a source or a
    /// frame producer, and the view is visible. While it runs, the view
    /// requests a frame on every display update of its window; otherwise the
    /// glow is drawn only when something else requests a frame.
    public var isAnimating: Bool {
        effectClockRunning
    }

    /// Holds the effect clock still while `true` (experimental): nothing
    /// animates, ``isAnimating`` is `false`, and the effect time stays where
    /// it was (0 if the clock never ran), so a still moment can be shown by
    /// setting each animated parameter's `timeOffset`. The default is `false`.
    /// Pausing and resuming do not jump the effect time.
    public var isEffectClockPaused = false {
        didSet {
            guard isEffectClockPaused != oldValue else { return }
            updateEffectClock()
        }
    }

    /// The effect clock's time, in seconds, given to the renderer at each
    /// draw. It advances only while ``isAnimating``.
    private(set) var effectClock = EffectClock()
    /// Whether the effect clock runs (``isAnimating``).
    private var effectClockRunning = false
    /// The update link that ticks the effect clock and tells the display the
    /// motion class's frame rate range; present only while the clock runs or
    /// an interaction is active.
    private var updateLink: UIUpdateLink?

    // MARK: Pacing and quality state (GW-27)

    /// The app's declared resting motion class. See ``motionClass``.
    private var restingMotionClass: GlassMotionClass = .ambient
    /// Open ``beginInteraction()`` calls.
    private var interactionCount = 0
    /// An environment change arrived during an interaction and waits for
    /// its end.
    private var environmentRefreshDeferred = false
    private var requestedQuality: GlassQuality = .full
    private var requestedQualityEnvironmentSource: QualityEnvironmentSource = .fixed(.nominal)

    /// The panels as the app set them, after the normalization rule.
    private var requestedPanels: [GlassPanel] = []

    // MARK: Touch state (GW-12)

    /// The touches being answered, on the effect clock.
    private var touchTracker = GlassTouchTracker()
    /// Frozen touches for captures and previews: where, how long ago the touch
    /// began, and how long it was held (`nil` while still down).
    private var pinnedTouches: [(origin: CGPoint, position: CGPoint, age: Double, held: Double?)] = []

    let scheduler = FrameScheduler(isVisible: false)
    private let metalView: MTKView
    private let metalLayer: CAMetalLayer
    /// Takes drawables off the main thread; see ``DrawableAcquirer``.
    private let acquirer: DrawableAcquirer
    /// A drawable acquisition or a deferred pass is outstanding.
    private var isPassOutstanding = false
    private let drawDelegate = DrawDelegate()
    /// The window scene whose lifecycle messages are observed, and the
    /// observations. Replacing the tokens ends the previous observations.
    private weak var observedScene: UIWindowScene?
    private var sceneObservations: [NotificationCenter.ObservationToken] = []

    public init(renderer: GlassRenderer) {
        self.renderer = renderer
        self.metalView = MTKView(frame: .zero, device: renderer.device)
        // An `MTKView`'s backing layer is a `CAMetalLayer`.
        guard let metalLayer = metalView.layer as? CAMetalLayer else {
            preconditionFailure("MTKView's layer is not a CAMetalLayer")
        }
        self.metalLayer = metalLayer
        self.acquirer = DrawableAcquirer(layer: metalLayer)
        super.init(frame: .zero)

        metalView.colorPixelFormat = GlassRenderer.outputPixelFormat
        metalView.framebufferOnly = true
        // Event-driven drawing: no display loop runs while nothing changes.
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        // The drawable size comes from local bounds and display scale.
        metalView.autoResizeDrawable = false
        metalView.isOpaque = true
        metalView.isUserInteractionEnabled = false
        metalView.isAccessibilityElement = false
        metalView.isHidden = true
        drawDelegate.surface = self
        metalView.delegate = drawDelegate
        addSubview(metalView)

        isOpaque = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .secondarySystemBackground

        registerForTraitChanges([UITraitDisplayScale.self]) { (self: Self, _) in
            self.updatePixelSize()
        }
        // The opaque surface color resolves for these traits.
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (self: Self, _) in
            self.presentPanels()
        }
        let center = NotificationCenter.default
        for name in [
            UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            UIAccessibility.reduceMotionStatusDidChangeNotification,
        ] {
            center.addObserver(self, selector: #selector(systemAccessibilitySettingsChanged), name: name, object: nil)
        }
        for name in [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange] {
            center.addObserver(self, selector: #selector(systemQualityEnvironmentChanged), name: name, object: nil)
        }
        refreshAccessibilitySettings()
        qualityEnvironment = environmentFromSource()
        qualityResolution = GlassQualityResolution(requested: requestedQuality, environment: qualityEnvironment)
    }

    /// Thermal and power notifications can arrive on any thread.
    @objc private nonisolated func systemQualityEnvironmentChanged() {
        Task { @MainActor [weak self] in self?.refreshQualityEnvironment() }
    }

    @objc private func systemAccessibilitySettingsChanged() {
        refreshAccessibilitySettings()
    }

    /// Reads the settings from the source and applies them if they changed.
    private func refreshAccessibilitySettings() {
        let settings: GlassAccessibilitySettings = switch accessibilitySettingsSource {
        case .system: .system
        case let .fixed(settings): settings
        }
        guard settings != accessibilitySettings else { return }
        accessibilitySettings = settings
        presentPanels()
        accessibilitySettingsHandler?(settings)
    }

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

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Validates and presents a new source frame.
    ///
    /// On error the previous source stays current.
    public func setSource(_ lease: BackgroundFrameLease) throws(BackgroundSourceError) {
        try renderer.setSource(lease)
        metalView.isHidden = false
        scheduleFrame()
        updateEffectClock()
    }

    /// The first panel the app set, in this view's points, after the
    /// `GlassParameters` normalization rule; `nil` for none. After
    /// ``setPanel(_:)`` it is that panel.
    public var panel: GlassPanel? {
        requestedPanels.first
    }

    /// The panels the app set, in drawing order, in this view's points,
    /// after the `GlassParameters` normalization rule: at most
    /// `GlassRenderer.maximumPanelCount`.
    public var panels: [GlassPanel] {
        requestedPanels
    }

    /// The first panel actually drawn: ``panel`` after
    /// ``GlassAccessibilityPolicy`` for the current ``accessibilitySettings``
    /// and traits.
    public var presentedPanel: GlassPanel? {
        renderer.panel
    }

    /// The panels actually drawn: each of ``panels`` after
    /// ``GlassAccessibilityPolicy`` for the current ``accessibilitySettings``
    /// and traits.
    public var presentedPanels: [GlassPanel] {
        renderer.panels
    }

    /// Sets the one panel, in this view's coordinate space and points, and
    /// redraws if it changed: ``setPanels(_:)`` with a list of that panel, or
    /// an empty list for `nil`. A non-finite value throws and leaves the
    /// current panels in place.
    public func setPanel(_ panel: GlassPanel?) throws(GlassParameterError) {
        try setPanels(panel.map { [$0] } ?? [])
    }

    /// Sets the panels, in drawing order, in this view's coordinate space and
    /// points, and redraws once if what is drawn changed. Each panel follows
    /// the `GlassParameters` normalization rule: a non-finite value in any of
    /// them throws and leaves the current panels in place, and only the first
    /// `GlassRenderer.maximumPanelCount` are kept. The accessibility policy
    /// applies to each panel, and the effect clock runs while any presented
    /// panel animates.
    public func setPanels(_ panels: [GlassPanel]) throws(GlassParameterError) {
        requestedPanels = try GlassPanel.normalized(panels)
        presentPanels()
    }

    /// Draws ``panels`` as the accessibility policy says, redrawing if that
    /// changes what is drawn, and starts or stops the effect clock.
    private func presentPanels() {
        // The quality tier first, then the accessibility policy: Reduce
        // Transparency and Increase Contrast draw their opaque body at every
        // tier, and Reduce Motion stills whatever the tier left moving.
        let tier = qualityResolution.quality
        let presented = requestedPanels.map {
            GlassAccessibilityPolicy.presentedPanel(for: tier.reduced($0), settings: accessibilitySettings, traits: traitCollection)
        }
        // Reduce Transparency presents any frost as none (the policy row also
        // clears each panel's own frost): its body is opaque, so no pyramid is
        // built. Increase Contrast raises a legibility scrim to 7:1; Reduce
        // Motion leaves the frost as it is (it is static).
        renderer.isFrostSuppressed = accessibilitySettings.reduceTransparency
        if presented != renderer.panels {
            // A presented panel derives from a normalized one and keeps every
            // value in range, so the renderer never rejects it.
            try? renderer.setPanels(presented)
            scheduleFrame()
        }
        reconcileTouches()
        updateEffectClock()
    }

    // MARK: Pacing and quality (GW-27, experimental)

    /// The motion class while no interaction is active: ``GlassMotionClass/ambient``
    /// by default. It sets the frame rate range the effect clock asks the
    /// display for (``effectFrameRate``). Setting `.interaction` here keeps the
    /// interaction rates on for good.
    public var motionClass: GlassMotionClass {
        get { restingMotionClass }
        set {
            guard newValue != restingMotionClass else { return }
            restingMotionClass = newValue
            updateEffectClock()
        }
    }

    /// The class in force now: ``GlassMotionClass/interaction`` while an
    /// interaction is open, ``motionClass`` otherwise.
    public var activeMotionClass: GlassMotionClass {
        isInteracting ? .interaction : restingMotionClass
    }

    /// Whether an interaction is open (``beginInteraction()``).
    public var isInteracting: Bool {
        interactionCount > 0
    }

    /// The app says the user is moving the glass, or what is under it, with a
    /// finger. The surface takes no touches itself, so it cannot know.
    ///
    /// While at least one interaction is open the surface asks the display
    /// for the interaction rates (80 to 120 Hz at ``GlassQuality/full``) by
    /// running its update link, even when no effect moves; it requests no
    /// frames of its own for that, the app still calls ``requestFrame()`` or
    /// produces its source. Calls nest: each ``beginInteraction()`` needs an
    /// ``endInteraction()``. An iPhone above 60 Hz also needs the app's
    /// `CADisableMinimumFrameDurationOnPhone` Info.plist key.
    ///
    /// A change of the power or thermal environment that arrives during an
    /// interaction waits for its end, so the tier never changes under the
    /// user's finger.
    public func beginInteraction() {
        interactionCount += 1
        if interactionCount == 1 { updateEffectClock() }
    }

    /// Closes one ``beginInteraction()``. Without an open interaction it does
    /// nothing. When the last one closes, a deferred environment change is
    /// applied and the frame rate range returns to the resting class.
    public func endInteraction() {
        guard interactionCount > 0 else { return }
        interactionCount -= 1
        guard interactionCount == 0 else { return }
        if environmentRefreshDeferred { applyQualityEnvironment() }
        updateEffectClock()
    }

    /// The frame rate range the effect clock asks the display for now: the
    /// ``activeMotionClass``'s range, capped by the quality tier and the
    /// thermal state.
    public var effectFrameRate: GlassFrameRate {
        activeMotionClass.frameRate(for: qualityResolution)
    }

    /// The tier the app asked for; ``GlassQuality/full`` by default. The
    /// tier in force can be lower (``effectiveQuality``). Changing it
    /// redraws the panels at the new tier.
    public var quality: GlassQuality {
        get { requestedQuality }
        set {
            guard newValue != requestedQuality else { return }
            requestedQuality = newValue
            applyQuality()
        }
    }

    /// Where ``qualityEnvironment`` comes from.
    public enum QualityEnvironmentSource: Hashable, Sendable {
        /// Low Power Mode and the thermal state, updated when the system
        /// posts a change.
        case system
        /// Fixed values, for tests, previews, and comparison runs.
        case fixed(GlassQualityEnvironment)
    }

    /// Where ``qualityEnvironment`` comes from. The default is
    /// `.fixed(.nominal)`: nothing is downgraded and nothing changes for an
    /// app that does not ask. Set `.system` to follow Low Power Mode and the
    /// thermal state. Setting it applies the new environment at once (or at
    /// the end of an open interaction).
    public var qualityEnvironmentSource: QualityEnvironmentSource {
        get { requestedQualityEnvironmentSource }
        set {
            requestedQualityEnvironmentSource = newValue
            refreshQualityEnvironment()
        }
    }

    /// The power and thermal environment currently applied.
    public private(set) var qualityEnvironment = GlassQualityEnvironment.nominal

    /// The tier and rate cap in force: ``quality`` after the environment's
    /// downgrade (``GlassQualityResolution``).
    public private(set) var qualityResolution = GlassQualityResolution(requested: .full, environment: .nominal)

    /// The tier drawn now.
    public var effectiveQuality: GlassQuality {
        qualityResolution.quality
    }

    /// Called when ``effectiveQuality`` changes, for example so the app can
    /// show a note or lighten its own source.
    public var qualityHandler: ((GlassQuality) -> Void)?

    private func environmentFromSource() -> GlassQualityEnvironment {
        switch requestedQualityEnvironmentSource {
        case .system: .system
        case let .fixed(environment): environment
        }
    }

    /// Reads the environment from its source and applies it, unless an
    /// interaction is open, which defers it to the interaction's end.
    private func refreshQualityEnvironment() {
        if isInteracting {
            environmentRefreshDeferred = true
        } else {
            applyQualityEnvironment()
        }
    }

    private func applyQualityEnvironment() {
        environmentRefreshDeferred = false
        qualityEnvironment = environmentFromSource()
        applyQuality()
    }

    /// Resolves the tier from the request and the environment, and redraws
    /// and re-rates if it changed.
    private func applyQuality() {
        let resolution = GlassQualityResolution(requested: requestedQuality, environment: qualityEnvironment)
        guard resolution != qualityResolution else { return }
        let previous = qualityResolution.quality
        qualityResolution = resolution
        presentPanels()
        if resolution.quality != previous {
            qualityHandler?(resolution.quality)
        }
    }

    // MARK: Touch response (GW-12, experimental)

    /// The touch styles of the panels as drawn: the ones that can draw a
    /// response, after the quality tier and the accessibility policy.
    private var presentedTouchStyles: [GlassTouch] {
        renderer.panels.map(\.parameters.touch).filter(\.isActive)
    }

    /// The number of touches the surface is answering now: fingers down, and
    /// ones whose light or ring has not finished.
    public var activeTouchCount: Int {
        touchTracker.count
    }

    /// A finger touched down at `point`, in this view's coordinate space
    /// (points). Experimental.
    ///
    /// The surface answers a touch only if it began inside a panel whose
    /// presented ``GlassParameters/touch`` can draw something (off by default,
    /// off under Reduce Transparency and at the minimal quality tier). Then it
    /// opens an interaction (``beginInteraction()``: the display's interaction
    /// rates), runs the effect clock while the ring or a fade moves, and closes
    /// the interaction when the response has settled, after which it draws no
    /// further frame. Up to two touches are answered at once; a third is
    /// ignored. `id` names the touch in the calls that follow; reusing the id
    /// of a touch that is down replaces it. A ``GlassTouchObserver`` makes
    /// these calls for the app.
    public func beginTouch(id: Int, at point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        let styles = presentedTouchStyles
        guard !styles.isEmpty,
              renderer.panels.contains(where: { $0.parameters.touch.isActive && $0.shapeBounds.contains(point) })
        else { return }
        let replaced = touchTracker.entries.contains { $0.id == id }
        guard touchTracker.begin(id: id, at: point, time: effectClock.time) else { return }
        if !replaced { beginInteraction() }
        touchesChanged()
    }

    /// The finger of touch `id` moved to `point`, in this view's coordinate
    /// space. The finger light and the rim gleam follow it; the ring keeps
    /// spreading from where the touch began. Ignored for an unknown touch.
    public func moveTouch(id: Int, to point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite, touchTracker.move(id: id, to: point) else { return }
        scheduleFrame()
    }

    /// The finger of touch `id` lifted. The light and the gleam fade over
    /// ``GlassTouch/fadeOut``; the ring finishes its travel. Ignored for an
    /// unknown touch.
    public func endTouch(id: Int) {
        guard touchTracker.end(id: id, time: effectClock.time) else { return }
        touchesChanged()
    }

    /// Touch `id` was cancelled by the system or by another gesture. The
    /// response ends as for ``endTouch(id:)``. Ignored for an unknown touch.
    public func cancelTouch(id: Int) {
        endTouch(id: id)
    }

    /// Shows a frozen touch for captures and previews (experimental): one that
    /// began `age` seconds ago at `point` (in this view's space), and, with
    /// `heldFor`, lifted that many seconds after it began (`nil` keeps it
    /// down). It is drawn as the response is at that age and never moves, opens
    /// no interaction and runs no clock; ``clearPinnedTouches()`` removes it.
    /// It follows the same rules as a real touch: it needs a panel with a touch
    /// style that contains `point`, and tiers and accessibility settings change
    /// what it shows. At most two are kept.
    public func pinTouch(at point: CGPoint, age: Double, heldFor: Double? = nil) {
        guard point.x.isFinite, point.y.isFinite, age.isFinite, heldFor?.isFinite ?? true else { return }
        pinnedTouches.append((point, point, max(age, 0), heldFor.map { max($0, 0) }))
        pinnedTouches = Array(pinnedTouches.suffix(GlassTouch.maximumTouchCount))
        scheduleFrame()
    }

    /// Removes the touches ``pinTouch(at:age:heldFor:)`` pinned.
    public func clearPinnedTouches() {
        guard !pinnedTouches.isEmpty else { return }
        pinnedTouches.removeAll()
        scheduleFrame()
    }

    /// Every touch the next draw answers, at effect time `time`: the live ones
    /// and the pinned ones (which are always `age` old).
    private func touchPoints(at time: Double) -> [GlassTouchPoint] {
        let pinned = pinnedTouches.map { pin -> GlassTouchPoint in
            let began = time - pin.age
            return GlassTouchPoint(origin: pin.origin, position: pin.position, beganAt: began, endedAt: pin.held.map { began + $0 })
        }
        return Array((touchTracker.points + pinned).prefix(GlassTouch.maximumTouchCount))
    }

    /// A touch began, moved to a new phase or ended: settle what is done,
    /// draw, and start or stop the clock.
    private func touchesChanged() {
        settleTouches()
        scheduleFrame()
        updateEffectClock()
    }

    /// Removes the touches whose response is over (closing the interaction each
    /// opened), at the effect clock's time.
    private func settleTouches() {
        let styles = presentedTouchStyles
        let removed = touchTracker.removeSettled(styles: styles, time: effectClock.time)
        for _ in 0..<removed { endInteraction() }
    }

    /// Drops every touch when no presented panel can answer one any more
    /// (Reduce Transparency, the minimal tier, a new set of panels).
    private func reconcileTouches() {
        guard !touchTracker.isEmpty, presentedTouchStyles.isEmpty else { return }
        let removed = touchTracker.removeAll()
        for _ in 0..<removed { endInteraction() }
    }

    // MARK: Effect clock

    /// Effect time in seconds, advanced by the model time between display
    /// updates while the clock runs. Restarting continues from the time
    /// reached, so a pulse resumes where it stopped instead of jumping.
    struct EffectClock: Equatable {
        private(set) var time: Double = 0
        /// The model time of the last update since the clock started, or
        /// `nil` before the first one.
        private var lastModelTime: Double?

        /// Starts a new running period: its first update only sets the base.
        mutating func start() {
            lastModelTime = nil
        }

        /// Advances by the model time since the previous update (never
        /// backward).
        mutating func advance(toModelTime modelTime: Double) {
            guard modelTime.isFinite else { return }
            if let lastModelTime {
                time += max(modelTime - lastModelTime, 0)
            }
            lastModelTime = modelTime
        }
    }

    /// Whether the effect clock should run now: the view is visible, has a
    /// source or a producer, and a presented panel whose parameters animate
    /// (``GlassParameters/isAnimated``: a glow pulse, a moving interior, an
    /// animated inner light, or a wobbling shape) can change a pixel of the
    /// drawable. The panels are the presented ones, so the quality tier and
    /// the accessibility policy have already steadied what they steady (Reduce
    /// Motion stills every one of them). A tick for a panel that cannot would
    /// only present the same pixels again.
    private var wantsEffectClock: Bool {
        guard !isEffectClockPaused, isVisible, renderer.currentFrame != nil || frameProducer != nil else { return false }
        let scale = Double(traitCollection.displayScale)
        // A touch whose ring or fade is still moving also runs the clock (GW-12).
        if touchTracker.isAnimating(styles: presentedTouchStyles, time: effectClock.time) { return true }
        return renderer.panels.contains { panel in
            panel.parameters.isAnimated
                && panel.reachesTarget(pixelWidth: pixelSize.width, pixelHeight: pixelSize.height, displayScale: scale)
        }
    }

    /// Starts or stops the effect clock and the update link to match
    /// ``wantsEffectClock`` and the active interaction, and tells the link the
    /// frame rate range of the active motion class.
    private func updateEffectClock() {
        let wantsClock = wantsEffectClock
        if wantsClock != effectClockRunning {
            effectClockRunning = wantsClock
            if wantsClock { effectClock.start() }
        }
        // An interaction also needs the link, to ask the display for its
        // high rates even when no effect moves; it requests no frames itself.
        if wantsClock || (isInteracting && isVisible) {
            if updateLink == nil {
                // The link belongs to this view, so it follows this view's
                // own window and display (never a global display link), and
                // its handler holds the view weakly.
                let link = UIUpdateLink(view: self) { [weak self] _, info in
                    self?.effectTick(modelTime: info.modelTime)
                }
                // Without continuous updates the link only observes updates
                // something else causes; the pulse needs every one.
                link.requiresContinuousUpdates = true
                link.isEnabled = true
                updateLink = link
            }
            let rate = effectFrameRate
            updateLink?.preferredFrameRateRange = CAFrameRateRange(
                minimum: rate.minimum, maximum: rate.maximum, preferred: rate.preferred
            )
        } else if let updateLink {
            updateLink.isEnabled = false
            self.updateLink = nil
        }
    }

    /// One display update of the effect clock: advance the effect time and
    /// request a frame through the scheduler. Ignored when the clock is not
    /// running.
    func effectTick(modelTime: Double) {
        guard effectClockRunning else { return }
        effectClock.advance(toModelTime: modelTime)
        // A touch whose response is over leaves, closing its interaction; the
        // frame requested below is the last one that shows it (GW-12).
        settleTouches()
        guard wantsEffectClock else {
            // Nothing moves any more (a settled touch, a finger held after its
            // ring): this frame is the last of the clock, which stops now so no
            // further tick draws. The link itself is removed outside its own
            // callback.
            effectClockRunning = false
            requestFrame()
            Task { @MainActor [weak self] in self?.updateEffectClock() }
            return
        }
        requestFrame()
    }

    /// The frame rate range the update link asks for, for tests.
    var updateLinkFrameRateRange: CAFrameRateRange? {
        updateLink?.preferredFrameRateRange
    }

    /// Makes every draw produce its own frame first.
    ///
    /// With a producer set, each draw (from ``requestFrame()``, a resize, a
    /// display-scale change, or a panel change) asks it for a frame at the
    /// current pixel size, inside the draw's command buffer, and presents
    /// that frame with the panel. The background and the refraction always
    /// sample the frame produced for that draw. The app's own clock decides
    /// when to call ``requestFrame()``; the view runs no display loop.
    ///
    /// Pass `nil` to stop producing; the last frame stays the source.
    public func setFrameProducer(_ producer: FrameProducer?) {
        frameProducer = producer
        if producer != nil {
            metalView.isHidden = false
            scheduleFrame()
        } else if renderer.currentFrame == nil {
            metalView.isHidden = true
        }
        updateEffectClock()
    }

    /// Requests one draw. Requests before the next display pass coalesce
    /// into one draw; while the view is not visible or at the in-flight
    /// bound, the draw stays pending (see the scheduling rules above).
    public func requestFrame() {
        refreshVisibility()
        scheduleFrame()
    }

    /// Removes the source and shows the opaque fallback. A frame producer,
    /// if set, keeps producing on the next draw.
    public func clearSource() {
        renderer.clearSource()
        metalView.isHidden = frameProducer == nil
        if frameProducer != nil {
            scheduleFrame()
        } else {
            // The defined skip, recorded without a draw: with no source the
            // renderer would return before touching a drawable.
            record(.skipped(.missingSource))
        }
        updateEffectClock()
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
        refreshVisibility()
        updatePixelSize()
    }

    // MARK: Scheduling and visibility

    /// Records a request and asks for a display pass when one may draw now.
    private func scheduleFrame() {
        if scheduler.request() {
            requestDisplayPass()
        }
    }

    /// Asks for a draw as soon as one can happen, without waiting for a
    /// drawable on the main thread.
    ///
    /// When a frame is pending, the view is visible and below the in-flight
    /// bound, and the draw needs a drawable, a background queue takes one
    /// from the layer (``DrawableAcquirer``) and the draw runs on the main
    /// thread when it arrives. A draw that needs none (no source, no area)
    /// runs on the next main-thread turn and skips as ``lastRenderOutcome``
    /// says. At most one such pass is outstanding; requests meanwhile merge
    /// into the pending frame. A surface that is not in a window never
    /// draws by itself (tests draw it with `renderNow()`).
    private func requestDisplayPass() {
        guard window != nil, !isPassOutstanding else { return }
        let ledger = scheduler.snapshot
        guard ledger.hasPendingFrame, ledger.isVisible,
              ledger.statistics.framesInFlight < ledger.maxFramesInFlight
        else { return }
        isPassOutstanding = true
        if wantsDrawable {
            acquirer.acquire { [weak self] acquired in
                self?.drawableAcquired(acquired.drawable)
            }
        } else {
            Task { @MainActor [weak self] in self?.drawableAcquired(nil, wasRequested: false) }
        }
    }

    /// Whether a draw now would take a drawable: it has a source or a
    /// producer, and a target with area.
    private var wantsDrawable: Bool {
        (renderer.currentFrame != nil || frameProducer != nil) && pixelSize.width > 0 && pixelSize.height > 0
    }

    /// The acquisition finished (`drawable` is `nil` when the layer timed
    /// out), or a pass that needs no drawable is due.
    private func drawableAcquired(_ drawable: (any CAMetalDrawable)?, wasRequested: Bool = true) {
        isPassOutstanding = false
        if !wasRequested {
            // The state may have changed while the pass waited: a draw that
            // now needs a drawable must get one first, or it would skip and
            // lose the pending frame.
            if wantsDrawable { requestDisplayPass() } else { render(.none) }
            return
        }
        guard let drawable else {
            // Nothing was free for the layer's whole timeout. The frame is
            // still pending; look again shortly, as long as it can draw.
            drawableTimeouts += 1
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                self?.requestDisplayPass()
            }
            return
        }
        // The layer was resized while the drawable was on its way: it has
        // the old size, and the resize's own request must not draw into it.
        let layerSize = metalLayer.drawableSize
        guard wantsDrawable, drawable.texture.width == Int(layerSize.width), drawable.texture.height == Int(layerSize.height) else {
            requestDisplayPass()
            return
        }
        render(.provided(drawable))
    }

    /// Stands in for the window and window scene, for tests: a test process
    /// has no connected scenes, so no surface there is ever on screen. With
    /// an override the view behaves as if it were in a window whose scene is
    /// in that state; its own and its ancestors' hidden state still count.
    /// The laboratory's UI tests cover the real UIKit path.
    var sceneStateOverride: SurfaceVisibility.SceneState? {
        didSet { refreshVisibility() }
    }

    /// Recomputes visibility from the view's window, hierarchy, and own
    /// window scene.
    private func refreshVisibility() {
        let sceneState = sceneStateOverride
            ?? window?.windowScene.map { SurfaceVisibility.SceneState($0.activationState) }
            ?? .none
        applyVisibility(SurfaceVisibility(
            isInWindow: sceneStateOverride != nil || window != nil,
            isHiddenInHierarchy: isHiddenInHierarchy,
            sceneState: sceneState
        ))
    }

    /// Whether this view or an ancestor is hidden or fully transparent.
    private var isHiddenInHierarchy: Bool {
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha <= 0.01 { return true }
            view = current.superview
        }
        return false
    }

    /// Applies observed visibility to the scheduler.
    private func applyVisibility(_ observation: SurfaceVisibility) {
        let visible = observation.isVisible
        guard visible != isVisible else { return }
        isVisible = visible
        if scheduler.setVisible(visible) {
            requestDisplayPass()
        }
        updateEffectClock()
        // A hidden surface gives back its frost pyramids (none exist
        // unless frost was requested); the next draw builds them again.
        if !visible { renderer.trimFrostResources() }
        // Hiding frees nothing else here: `MTKView.releaseDrawables()` releases
        // only depth/stencil and multisample textures, which this view does
        // not create, and the layer keeps its drawable pool. Memory a hidden
        // surface can give back is the app's (see `visibilityHandler`).
        visibilityHandler?(visible)
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

    /// Recomputes the target size from local bounds and the display scale,
    /// requests a draw when it changed, and looks again at whether a panel's
    /// animation can reach the drawable.
    private func updatePixelSize() {
        defer { updateEffectClock() }
        let scale = traitCollection.displayScale
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        let newSize = (width: max(width, 0), height: max(height, 0))
        if scale > 0, metalView.contentScaleFactor != scale {
            metalView.contentScaleFactor = scale
        }
        guard newSize != pixelSize else { return }
        pixelSize = newSize
        // A zero size is a defined skip; the layer keeps its last valid
        // drawable size instead of being asked for an empty one.
        if newSize.width > 0, newSize.height > 0 {
            metalView.drawableSize = CGSize(width: newSize.width, height: newSize.height)
        }
        scheduleFrame()
    }

    /// Where a draw gets its drawable.
    private enum DrawableSource {
        /// One the background acquisition delivered.
        case provided(any CAMetalDrawable)
        /// None: the draw must skip before it needs one.
        case none
        /// Asked from the layer on the calling thread, which can wait up to
        /// the layer's timeout. Only `renderNow()` does this.
        case synchronous
    }

    /// Draws if the scheduler permits a draw now.
    private func render(_ source: DrawableSource) {
        // An ancestor's hidden state is not observable; check it here so a
        // hidden surface never draws.
        refreshVisibility()
        // A pass with nothing requested draws nothing (on demand).
        guard scheduler.beginDraw() == .draw else { return }
        // Acquire the drawable as late as possible: after the checks and
        // after any frame production has been encoded.
        let acquireTarget = { [metalView] () -> BackgroundDrawTarget? in
            switch source {
            case let .provided(drawable):
                let descriptor = MTLRenderPassDescriptor()
                descriptor.colorAttachments[0].texture = drawable.texture
                descriptor.colorAttachments[0].loadAction = .clear
                descriptor.colorAttachments[0].storeAction = .store
                descriptor.colorAttachments[0].clearColor = metalView.clearColor
                return BackgroundDrawTarget(renderPassDescriptor: descriptor, drawable: drawable)
            case .none:
                return nil
            case .synchronous:
                guard let descriptor = metalView.currentRenderPassDescriptor else { return nil }
                return BackgroundDrawTarget(renderPassDescriptor: descriptor, drawable: metalView.currentDrawable)
            }
        }
        var committed = false
        let onCommit = { [scheduler, weak self] (commandBuffer: any MTLCommandBuffer) in
            committed = true
            scheduler.drawCommitted()
            commandBuffer.addCompletedHandler { [weak self] _ in
                // A frame deferred at the bound is pending; draw it now that
                // a slot is free.
                guard scheduler.frameCompleted() else { return }
                Task { @MainActor [weak self] in self?.requestDisplayPass() }
            }
        }
        let scale = traitCollection.displayScale
        // The effect clock's time is always finite.
        try? renderer.setEffectTime(effectClock.time)
        try? renderer.setTouches(touchPoints(at: effectClock.time))
        let outcome: BackgroundRenderOutcome?
        if let frameProducer {
            do {
                outcome = try renderer.drawProducing(
                    targetPixelSize: pixelSize, displayScale: scale,
                    produce: frameProducer, acquireTarget: acquireTarget, onCommit: onCommit
                )
                lastProducedFrameError = nil
            } catch {
                // The previous source stays; the next request tries again.
                lastProducedFrameError = error
                outcome = nil
            }
        } else {
            outcome = renderer.draw(targetPixelSize: pixelSize, displayScale: scale, acquireTarget: acquireTarget, onCommit: onCommit)
        }
        // End the draw before the app's observer runs, so a request it makes
        // finds the slot a skipped draw frees. A request or completion that
        // arrived during a skipped draw left its wake-up to this point, and
        // no completion of this draw will deliver it.
        if !committed, scheduler.drawSkipped() {
            requestDisplayPass()
        }
        if let outcome {
            record(outcome)
        }
    }

    /// The `MTKView` asked to display (UIKit does this on its own at times).
    /// The surface draws only through its own acquisition, so this is just
    /// another request for that.
    fileprivate func displayRequestedBySystem() {
        requestDisplayPass()
    }

    private func record(_ outcome: BackgroundRenderOutcome) {
        lastRenderOutcome = outcome
        renderObserver?(outcome)
    }

    /// Draws immediately, for tests that cannot wait for a display pass.
    func renderNow() {
        render(.synchronous)
    }

    /// The hosted Metal view, for tests.
    var hostedMetalView: MTKView { metalView }
}

/// What a surface observes about where it is shown, reduced to whether it
/// should draw.
struct SurfaceVisibility: Hashable {
    /// The activation state of the surface's own window scene.
    enum SceneState: Hashable {
        case foregroundActive
        case foregroundInactive
        case background
        case unattached
        /// The window has no scene, so it is not on screen.
        case none

        init(_ state: UIScene.ActivationState) {
            switch state {
            case .foregroundActive: self = .foregroundActive
            case .foregroundInactive: self = .foregroundInactive
            case .background: self = .background
            case .unattached: self = .unattached
            @unknown default: self = .background
            }
        }
    }

    var isInWindow: Bool
    /// The surface or an ancestor is hidden or fully transparent.
    var isHiddenInHierarchy: Bool
    var sceneState: SceneState

    /// A foreground scene is on screen whether or not it receives events, so
    /// an inactive scene (for example beside an active one) keeps drawing.
    var isVisible: Bool {
        guard isInWindow, !isHiddenInHierarchy else { return false }
        switch sceneState {
        case .foregroundActive, .foregroundInactive: return true
        case .background, .unattached, .none: return false
        }
    }
}

/// Forwards `MTKView` callbacks without exposing the conformance publicly.
@MainActor
private final class DrawDelegate: NSObject, MTKViewDelegate {
    weak var surface: GlassSurfaceView?

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        surface?.displayRequestedBySystem()
    }
}
#endif
