#if canImport(UIKit)
import GlassWeave
import MetalKit
import UIKit

/// Presents an explicit background source, with an optional rounded glass
/// panel over it, through an `MTKView`, on demand.
///
/// The view draws only when something changes: a new source, a new panel, a
/// new pixel size, or a display-scale change. No display loop runs in
/// between. The panel is given in this view's points and converted with the
/// same display scale as the drawable. The view
/// sizes its drawable from its own bounds and `traitCollection.displayScale`,
/// never from a screen or a global scene.
///
/// Defined skips, none of which waits on the GPU or the main thread:
/// - No source: the Metal view is hidden and the opaque `backgroundColor`
///   shows as the fallback. ``lastRenderOutcome`` is
///   `.skipped(.missingSource)`.
/// - Zero-size bounds or a zero display scale: no drawable is requested and
///   the outcome is `.skipped(.zeroSizeTarget)`.
/// - No drawable available: the outcome is `.skipped(.drawableUnavailable)`
///   and the producer's lease counts the skipped use.
///
/// The surface is decorative: it is not an accessibility element and does
/// not take touches, so native content placed above it keeps its behavior.
@MainActor
public final class GlassSurfaceView: UIView {
    public let renderer: GlassRenderer

    /// The result of the most recent draw request, for diagnostics.
    public private(set) var lastRenderOutcome: BackgroundRenderOutcome?

    /// Called after every draw request with its outcome.
    public var renderObserver: ((BackgroundRenderOutcome) -> Void)?

    /// The render target size in pixels: bounds times display scale, rounded
    /// to whole pixels. Zero in a dimension when the view has no area.
    public private(set) var pixelSize: (width: Int, height: Int) = (0, 0)

    private let metalView: MTKView
    private let drawDelegate = DrawDelegate()

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
        backgroundColor = .secondarySystemBackground

        registerForTraitChanges([UITraitDisplayScale.self]) { (self: Self, _) in
            self.updatePixelSize()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Validates and presents a new source frame.
    ///
    /// On error the previous source stays current.
    public func setSource(_ lease: BackgroundFrameLease) throws(BackgroundSourceError) {
        try renderer.setSource(lease)
        metalView.isHidden = false
        metalView.setNeedsDisplay()
    }

    /// The panel drawn over the source, in this view's points, after the
    /// ``GlassParameters`` normalization rule; `nil` for none.
    public var panel: GlassPanel? {
        renderer.panel
    }

    /// Sets the panel, in this view's coordinate space and points, and
    /// redraws if it changed. A non-finite value throws and leaves the
    /// current panel in place.
    public func setPanel(_ panel: GlassPanel?) throws(GlassParameterError) {
        let previous = renderer.panel
        try renderer.setPanel(panel)
        if renderer.panel != previous {
            metalView.setNeedsDisplay()
        }
    }

    /// Removes the source and shows the opaque fallback.
    public func clearSource() {
        renderer.clearSource()
        metalView.isHidden = true
        // Record the defined skip; the renderer returns before touching a
        // drawable because no source is attached.
        render(in: metalView)
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
        updatePixelSize()
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
        metalView.setNeedsDisplay()
    }

    /// Draws through the same path the `MTKView` delegate uses.
    func render(in view: MTKView) {
        let outcome = renderer.draw(targetPixelSize: pixelSize, displayScale: traitCollection.displayScale) {
            // Acquire the drawable as late as possible.
            guard let descriptor = view.currentRenderPassDescriptor else { return nil }
            return BackgroundDrawTarget(renderPassDescriptor: descriptor, drawable: view.currentDrawable)
        }
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
