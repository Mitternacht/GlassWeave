#if canImport(UIKit)
import GlassWeave
import MetalKit
import UIKit

/// Presents an explicit background source, with an optional rounded glass
/// panel over it, through an `MTKView`, on demand.
///
/// The view draws only when something changes: a new source, a new panel, a
/// new pixel size, a display-scale change, or an app request through
/// ``requestFrame()``. No display loop runs in between; an app animating its
/// source drives redraws from its own clock and can produce each frame
/// inside the draw with ``setFrameProducer(_:)``. The panel is given in this
/// view's points and converted with the same display scale as the drawable.
/// The view sizes its drawable from its own bounds and
/// `traitCollection.displayScale`, never from a screen or a global scene.
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
/// Defined skips. None waits for GPU work; the first two return before a
/// drawable is requested:
/// - No source: the Metal view is hidden and the opaque `backgroundColor`
///   shows as the fallback. ``lastRenderOutcome`` is
///   `.skipped(.missingSource)`.
/// - Zero-size bounds or a zero display scale: no drawable is requested and
///   the outcome is `.skipped(.zeroSizeTarget)`.
/// - No drawable available: the outcome is `.skipped(.drawableUnavailable)`
///   and the producer's lease counts the skipped use. This skip is reached
///   only after a wait on the main thread: the view acquires its drawable
///   through `MTKView.currentRenderPassDescriptor`, which calls
///   `CAMetalLayer.nextDrawable()`, and that call blocks until a drawable is
///   free or the layer's one-second timeout passes. With at most
///   ``maximumFramesInFlight`` frames in flight the wait is normally at most
///   about one display refresh; when no drawable is free it can last up to
///   one second.
///
/// The surface is decorative: neither it nor its Metal view is an
/// accessibility element (its accessibility elements are hidden), and it
/// does not take touches, so native content placed above it keeps its
/// behavior and VoiceOver reaches only that content.
///
/// Accessibility settings (``accessibilitySettings``) change what is drawn
/// as ``GlassAccessibilityPolicy`` documents: under Reduce Transparency the
/// panel becomes an opaque surface (``presentedPanel``). By default the
/// view follows the system settings and their change notifications.
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

    /// The panel as the app set it, after the normalization rule.
    private var requestedPanel: GlassPanel?

    let scheduler = FrameScheduler(isVisible: false)
    private let metalView: MTKView
    private let drawDelegate = DrawDelegate()
    /// The window scene whose lifecycle messages are observed, and the
    /// observations. Replacing the tokens ends the previous observations.
    private weak var observedScene: UIWindowScene?
    private var sceneObservations: [NotificationCenter.ObservationToken] = []

    public init(renderer: GlassRenderer) {
        self.renderer = renderer
        self.metalView = MTKView(frame: .zero, device: renderer.device)
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
            self.presentPanel()
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
        presentPanel()
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
    }

    /// The panel the app set, in this view's points, after the
    /// `GlassParameters` normalization rule; `nil` for none.
    public var panel: GlassPanel? {
        requestedPanel
    }

    /// The panel actually drawn: ``panel`` after ``GlassAccessibilityPolicy``
    /// for the current ``accessibilitySettings`` and traits.
    public var presentedPanel: GlassPanel? {
        renderer.panel
    }

    /// Sets the panel, in this view's coordinate space and points, and
    /// redraws if it changed. A non-finite value throws and leaves the
    /// current panel in place.
    public func setPanel(_ panel: GlassPanel?) throws(GlassParameterError) {
        requestedPanel = try panel?.normalized()
        presentPanel()
    }

    /// Draws ``panel`` as the accessibility policy says, redrawing if that
    /// changes what is drawn.
    private func presentPanel() {
        let presented = requestedPanel.map {
            GlassAccessibilityPolicy.presentedPanel(for: $0, settings: accessibilitySettings, traits: traitCollection)
        }
        guard presented != renderer.panel else { return }
        // A presented panel derives from a normalized one and keeps every
        // value in range, so the renderer never rejects it.
        try? renderer.setPanel(presented)
        scheduleFrame()
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

    /// Whether ``render(in:)`` is drawing: the app's producer or observer
    /// may request a frame from inside the draw.
    private var isDrawing = false

    /// Asks the Metal view for a display pass. From inside a draw, the ask
    /// is made after the draw returns, so the pass that is running cannot
    /// absorb it.
    private func requestDisplayPass() {
        if isDrawing {
            Task { @MainActor [weak self] in self?.metalView.setNeedsDisplay() }
        } else {
            metalView.setNeedsDisplay()
        }
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
        // Hiding frees nothing here: `MTKView.releaseDrawables()` releases
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
    /// and requests a draw when it changed.
    private func updatePixelSize() {
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

    /// Draws through the same path the `MTKView` delegate uses, if the
    /// scheduler permits a draw now.
    func render(in view: MTKView) {
        // An ancestor's hidden state is not observable; check it here so a
        // hidden surface never draws.
        refreshVisibility()
        // A pass with nothing requested draws nothing (on demand).
        guard scheduler.beginDraw() == .draw else { return }
        isDrawing = true
        defer { isDrawing = false }
        // Acquire the drawable as late as possible: after the checks and
        // after any frame production has been encoded.
        let acquireTarget = { () -> BackgroundDrawTarget? in
            guard let descriptor = view.currentRenderPassDescriptor else { return nil }
            return BackgroundDrawTarget(renderPassDescriptor: descriptor, drawable: view.currentDrawable)
        }
        var committed = false
        let onCommit = { [scheduler, weak self] (commandBuffer: any MTLCommandBuffer) in
            committed = true
            scheduler.drawCommitted()
            commandBuffer.addCompletedHandler { [weak self] _ in
                // A frame deferred at the bound is pending; draw it now that
                // a slot is free.
                guard scheduler.frameCompleted() else { return }
                Task { @MainActor [weak self] in self?.metalView.setNeedsDisplay() }
            }
        }
        let scale = traitCollection.displayScale
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

    private func record(_ outcome: BackgroundRenderOutcome) {
        lastRenderOutcome = outcome
        renderObserver?(outcome)
    }

    /// Draws immediately, for tests that cannot wait for a display pass.
    func renderNow() {
        render(in: metalView)
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
        surface?.render(in: view)
    }
}
#endif
