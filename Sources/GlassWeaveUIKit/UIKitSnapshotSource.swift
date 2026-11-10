#if canImport(UIKit)
import CoreGraphics
import GlassWeave
import Metal
import UIKit

/// A value the snapshot source rejected.
///
/// > Important: Experimental. This API may change before a stable release.
public enum UIKitSnapshotError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The number that held the rejected value.
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case regionX, regionY, regionWidth, regionHeight
        case scale
        case budgetMilliseconds
    }

    /// A value was NaN or infinite, which has no nearest valid value.
    case nonFinite(Field)
    /// The region has no area, so there is nothing to capture.
    case emptyRegion
    /// Every pooled texture is still used by a frame in flight; nothing is
    /// written and nothing waits. Ask again after the next frame completes.
    case noFreeTexture
    /// Metal could not create a buffer, texture or command buffer.
    case resourceCreation(String)
    /// `UIView.drawHierarchy(in:afterScreenUpdates:)` was asked for and could
    /// not render the view (it is not in a window, or not on screen).
    case drawHierarchyFailed

    public var description: String {
        switch self {
        case let .nonFinite(field):
            "UIKitSnapshotSource: \(field.rawValue) is not a finite number. Pass a finite value; a finite value outside the range is clamped, a NaN or infinity is rejected."
        case .emptyRegion:
            "UIKitSnapshotSource: the region to capture has no area. Pass a region with a positive width and height inside the view, or omit it to capture the whole view."
        case .noFreeTexture:
            "UIKitSnapshotSource: every snapshot texture is still in use by a frame in flight. Nothing was captured; refresh again after the next frame completes."
        case let .resourceCreation(what):
            "UIKitSnapshotSource: Metal could not create \(what)."
        case .drawHierarchyFailed:
            "UIKitSnapshotSource: drawHierarchy could not render the view. It must be in a window that is on screen; use the layer technique for a view that is not."
        }
    }
}

/// Captures a region of a UIKit view hierarchy into a ``BackgroundFrame`` that a
/// ``GlassSurfaceView`` can refract and frost (GW-31).
///
/// > Important: Experimental. This API may change before a stable release.
///
/// Custom glass bends and blurs pixels it can read, and it cannot read what UIKit
/// draws behind it. This opt-in source closes part of that gap for **static**
/// content: it renders a view (a list, a card, a screen) into a texture on the
/// surface renderer's device, on demand, and hands it over as an ordinary source
/// frame. The glass then lenses and frosts the snapshot exactly as it does any
/// other source. It is not live: the texture shows the view as it was at the last
/// ``refresh(_:from:region:scale:technique:afterScreenUpdates:)`` or
/// ``capture(_:region:scale:technique:afterScreenUpdates:)``.
///
/// ```swift
/// let source = try UIKitSnapshotSource(renderer: surface.renderer)
/// try source.refresh(surface, from: tableView)   // after scrolling ends
/// ```
///
/// ## The contract
///
/// | Row | Value |
/// | --- | --- |
/// | Region | A rectangle in the captured view's own coordinate space (what `UIView.convert(_:from:)` returns), in points. The default for ``refresh(_:from:region:scale:technique:afterScreenUpdates:)`` is the surface's bounds converted into the view. Parts outside the view show the backdrop color. |
/// | Size and scale | `round(region × scale)` pixels, at least 1. The scale defaults to the view's `displayScale`, is clamped to 0.25...8, and is lowered further so the texture holds at most ``Configuration/maximumPixelCount`` pixels and 8192 in either dimension (``Report/wasScaledDown``). |
/// | Orientation | Upright: texture row 0 is the top of the region, column 0 its left edge (``SourceOrientation/up``). The frame's valid rectangle is the whole texture. |
/// | Mapping | The surface aspect-fills the source like any source. Give the surface the size of the region, point for point, and the snapshot lies under the glass pixel for pixel; a different aspect crops. |
/// | Color and alpha | ``BackgroundColorConvention/sRGBOpaque``: `bgra8Unorm_srgb`, sRGB-encoded, opaque. Content is converted to sRGB (wide-gamut colors clip) and composited over the opaque ``Configuration/backdrop`` (the system background of the view's traits by default), so no pixel is transparent. |
/// | Device and queue | The renderer's device. The upload is a blit committed to the renderer's own queue before the frame is handed over (``BackgroundFrameReadiness/committed(on:)``). |
/// | Frame identity | IDs increase by one per capture, starting after the renderer's current frame; timestamps are the time since this source was made, on top of the renderer's current frame's timestamp, so they never go backwards. |
/// | Ownership | Textures come from a ``FrameTexturePool``. A texture returns to it only when GlassWeave releases the frame, after the last GPU use, so a capture never writes into a texture the GPU can still read. When every texture is in use, a capture throws ``UIKitSnapshotError/noFreeTexture`` instead of waiting or allocating. |
///
/// ## What it captures
///
/// - ``Technique/drawHierarchy`` renders what the view shows on screen
///   (`UIView.drawHierarchy(in:afterScreenUpdates:)`): presentation state,
///   blurs and visual effects, system controls. The view must be in a window.
/// - ``Technique/layerRender`` renders the layer tree (`CALayer.render(in:)`):
///   it works for a view that is not on screen, ignores running animations
///   and leaves out content the layer tree cannot draw (visual effect views,
///   Metal layers, video).
///
/// Capture a view that does **not** contain the glass surface, or the glass
/// would be refracting itself. Content under a view that has a secure or
/// protected rendering is whatever UIKit draws for it.
///
/// ## Cost
///
/// A refresh runs on the main thread in one synchronous pass: the draw (nearly
/// all of the time), then one blit encoded and committed. It never waits for the
/// GPU and allocates one upload buffer of the texture's size (freed when the
/// blit completes). It is for use on demand, for example once when scrolling
/// ends, never per frame. The draw grows with the pixels captured and with the
/// view it renders; the first capture in a process costs more than later ones.
/// The library cannot interrupt a draw once it has started: instead each refresh
/// reports its measured time (``Report``), and ``Report/exceededBudget`` says
/// when it passed ``Configuration/budgetMilliseconds`` (33 ms by default, two
/// frames at 60 Hz). On the simulator a list-sized capture stays well inside it
/// (about 10 ms for a bar-sized region of a list, about 19 ms for the whole
/// list) and a full 1206 x 2622 screen does not (about 40 ms). The measured
/// numbers and the stated bound are in `docs/snapshot.md`.
///
/// ## Accessibility and privacy
///
/// The snapshot is decorative: the live views stay the accessibility elements
/// and receive every touch (the surface takes none). Under Reduce Transparency
/// the surface's own policy presents an opaque panel and the frost is
/// suppressed, whatever the source. A snapshot is a pixel copy of the view,
/// kept in GPU memory only and never written or sent; ``trim()`` releases the
/// textures while the host is hidden.
@MainActor
public final class UIKitSnapshotSource {
    /// How the view is rendered.
    public enum Technique: Hashable, Sendable {
        /// ``drawHierarchy`` when the view is in a window, otherwise
        /// ``layerRender``. ``Report/technique`` says which ran.
        case automatic
        /// What the view shows on screen; the view must be in a window.
        case drawHierarchy
        /// The layer tree, which needs no window.
        case layerRender
    }

    /// The settings of a source.
    public struct Configuration: Hashable {
        /// The opaque color the content is composited over, or `nil` for the
        /// system background of the captured view's traits. Its alpha is ignored.
        public var backdrop: UIColor?
        /// The most pixels one capture holds; a bigger region is captured at a
        /// lower scale. Clamped to 4,096...67,108,864. The default, 4,194,304
        /// (4 megapixels, 16 MiB), holds a full 1206 x 2622 iPhone screen at
        /// native scale. It bounds the texture's memory; the time of a refresh is
        /// reported, not bounded (see ``Report``).
        public var maximumPixelCount: Int
        /// How many textures the source keeps, in use or free. Clamped to 2...6.
        public var textureCount: Int
        /// The main-thread time a refresh should stay within, in milliseconds
        /// (non-negative, finite). A refresh that takes longer is reported
        /// through ``Report/exceededBudget``; it is not cancelled.
        public var budgetMilliseconds: Double

        public init(
            backdrop: UIColor? = nil, maximumPixelCount: Int = 4_194_304,
            textureCount: Int = 3, budgetMilliseconds: Double = 33
        ) {
            self.backdrop = backdrop
            self.maximumPixelCount = maximumPixelCount
            self.textureCount = textureCount
            self.budgetMilliseconds = budgetMilliseconds
        }

        /// The configuration after the normalization rule: a non-finite budget
        /// is rejected, every other out-of-range value is clamped.
        func normalized() throws(UIKitSnapshotError) -> Configuration {
            guard budgetMilliseconds.isFinite else { throw .nonFinite(.budgetMilliseconds) }
            var result = self
            result.maximumPixelCount = min(max(maximumPixelCount, 4_096), 67_108_864)
            result.textureCount = min(max(textureCount, 2), 6)
            result.budgetMilliseconds = max(budgetMilliseconds, 0)
            return result
        }
    }

    /// What one capture did, with its measured main-thread cost.
    public struct Report: Hashable, Sendable {
        /// The captured frame's ID.
        public var frameID: UInt64
        /// The texture's size in pixels.
        public var pixelWidth: Int
        public var pixelHeight: Int
        /// Pixels per point of the capture, after the clamps (horizontal).
        public var scale: Double
        /// The region captured, in the view's coordinate space, in points.
        public var region: CGRect
        /// The technique that ran (never ``Technique/automatic``).
        public var technique: Technique
        /// The scale was lowered to stay within the pixel limits.
        public var wasScaledDown: Bool
        /// Milliseconds on the main thread drawing the view into the buffer.
        public var drawMilliseconds: Double
        /// Milliseconds encoding and committing the upload blit.
        public var uploadMilliseconds: Double
        /// The whole call, in milliseconds.
        public var totalMilliseconds: Double
        /// ``totalMilliseconds`` passed ``Configuration/budgetMilliseconds``.
        public var exceededBudget: Bool
    }

    public let renderer: GlassRenderer
    public let configuration: Configuration
    /// The report of the last successful capture.
    public private(set) var lastReport: Report?
    /// How many captures succeeded.
    public private(set) var captureCount = 0

    private let pool: FrameTexturePool
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private let baseTimestamp: Duration
    private var nextFrameID: UInt64

    /// The largest texture dimension, in pixels.
    public static let maximumDimension = 8192
    /// The scale range, in pixels per point.
    public static let scaleRange: ClosedRange<Double> = 0.25...8

    /// Makes a source for `renderer`'s device and queue. Use one source per
    /// renderer: frame IDs must increase on a renderer, and this source
    /// continues after whatever frame the renderer shows now.
    public init(renderer: GlassRenderer, configuration: Configuration = Configuration()) throws(UIKitSnapshotError) {
        let configuration = try configuration.normalized()
        self.renderer = renderer
        self.configuration = configuration
        self.pool = FrameTexturePool(
            device: renderer.device,
            descriptor: .init(
                pixelFormat: BackgroundColorConvention.sRGBOpaque.requiredPixelFormat,
                usage: [.shaderRead], storageMode: .private
            ),
            capacity: configuration.textureCount
        )
        self.start = clock.now
        self.baseTimestamp = renderer.currentFrame?.timestamp ?? .zero
        self.nextFrameID = (renderer.currentFrame?.frameID ?? 0) + 1
    }

    /// What the texture pool holds now: textures in use, allocations, bytes.
    public var poolStatistics: FrameTexturePool.Statistics {
        pool.statistics
    }

    /// Releases every free texture now and every texture in use when its frame
    /// is released, for example while the host is hidden. The next capture
    /// allocates again.
    public func trim() {
        pool.trim()
    }

    /// Captures `view` and hands the frame to `surface`, which draws it on its
    /// next frame. The surface's renderer is not recreated, and a frost pyramid
    /// is rebuilt once for the new frame.
    ///
    /// - Parameters:
    ///   - surface: The glass surface to show the snapshot. Its renderer must be
    ///     the one this source was made for.
    ///   - view: The view to capture. It must not contain `surface`.
    ///   - region: The part of `view` to capture, in its coordinate space.
    ///     `nil` is the surface's bounds converted into `view`: the part of the
    ///     view the surface covers.
    ///   - scale: Pixels per point, or `nil` for the surface's `displayScale`.
    ///   - technique: How to render the view.
    ///   - afterScreenUpdates: Passed to `drawHierarchy`: `true` commits
    ///     pending changes first (use it right after the view changed), `false`
    ///     (the default) captures what is already on screen.
    /// - Returns: The capture's measurements.
    @discardableResult
    public func refresh(
        _ surface: GlassSurfaceView, from view: UIView, region: CGRect? = nil, scale: CGFloat? = nil,
        technique: Technique = .automatic, afterScreenUpdates: Bool = false
    ) throws -> Report {
        precondition(surface.renderer === renderer, "The surface must use the renderer this snapshot source was made for")
        let region = region ?? view.convert(surface.bounds, from: surface)
        let (lease, report) = try capture(
            view, region: region, scale: scale ?? surface.traitCollection.displayScale,
            technique: technique, afterScreenUpdates: afterScreenUpdates
        )
        // The producer's hold ends once the surface has the frame (or has
        // refused it): the texture then returns to the pool when the GPU is done.
        defer { lease.retire() }
        try surface.setSource(lease)
        return report
    }

    /// Renders `region` of `view` into a pooled texture and returns the frame's
    /// lease. The caller hands it to `GlassSurfaceView.setSource(_:)` (or the
    /// renderer's) and then calls `retire()` on it.
    ///
    /// - Parameters:
    ///   - view: The view to capture.
    ///   - region: The part of `view` to capture, in its coordinate space, in
    ///     points; `nil` is the view's bounds.
    ///   - scale: Pixels per point, or `nil` for the view's `displayScale`.
    ///   - technique: How to render the view.
    ///   - afterScreenUpdates: See ``refresh(_:from:region:scale:technique:afterScreenUpdates:)``.
    /// - Throws: ``UIKitSnapshotError``: a non-finite region or scale (naming the
    ///   field), an empty region, no free texture, a Metal failure, or a
    ///   `drawHierarchy` that could not render.
    public func capture(
        _ view: UIView, region: CGRect? = nil, scale: CGFloat? = nil,
        technique: Technique = .automatic, afterScreenUpdates: Bool = false
    ) throws -> (lease: BackgroundFrameLease, report: Report) {
        let began = clock.now
        let region = region ?? view.bounds
        let requestedScale = scale ?? view.traitCollection.displayScale

        // Normalization: reject non-finite, clamp the rest.
        for (value, field) in [
            (region.origin.x, UIKitSnapshotError.Field.regionX), (region.origin.y, .regionY),
            (region.size.width, .regionWidth), (region.size.height, .regionHeight),
            (requestedScale, .scale),
        ] where !value.isFinite {
            throw UIKitSnapshotError.nonFinite(field)
        }
        let area = region.standardized
        guard area.width > 0, area.height > 0 else { throw UIKitSnapshotError.emptyRegion }
        var effectiveScale = min(max(Double(requestedScale), Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        let requested = effectiveScale
        let pointArea = Double(area.width) * Double(area.height)
        effectiveScale = min(
            effectiveScale,
            (Double(configuration.maximumPixelCount) / pointArea).squareRoot(),
            Double(Self.maximumDimension) / Double(max(area.width, area.height))
        )
        let pixelWidth = max(Int((Double(area.width) * effectiveScale).rounded()), 1)
        let pixelHeight = max(Int((Double(area.height) * effectiveScale).rounded()), 1)
        // The two axes scale by their own rounding, so the content fills the
        // texture exactly.
        let scaleX = Double(pixelWidth) / Double(area.width)
        let scaleY = Double(pixelHeight) / Double(area.height)

        guard let pooled = pool.checkout(width: pixelWidth, height: pixelHeight) else {
            throw UIKitSnapshotError.noFreeTexture
        }
        // The CGContext draws straight into a shared buffer; one blit moves it
        // into the private texture. Rows are 256-byte aligned for the blit.
        let bytesPerRow = (pixelWidth * 4 + 255) & ~255
        let length = bytesPerRow * pixelHeight
        guard let buffer = renderer.device.makeBuffer(length: length, options: .storageModeShared),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: buffer.contents(), width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else {
            pool.returnUnused(pooled)
            throw UIKitSnapshotError.resourceCreation("the snapshot buffer")
        }

        let used: Technique
        do {
            used = try render(
                view, region: area, into: context, scaleX: scaleX, scaleY: scaleY,
                technique: technique, afterScreenUpdates: afterScreenUpdates
            )
        } catch {
            pool.returnUnused(pooled)
            throw error
        }
        let drawn = clock.now

        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else {
            pool.returnUnused(pooled)
            throw UIKitSnapshotError.resourceCreation("the upload command buffer")
        }
        blit.copy(
            from: buffer, sourceOffset: 0, sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: length,
            sourceSize: MTLSize(width: pixelWidth, height: pixelHeight, depth: 1),
            to: pooled.storage, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.label = "GlassWeave UIKit snapshot \(nextFrameID)"
        // The command buffer retains the upload buffer until the copy completes.
        commandBuffer.commit()

        let frame = BackgroundFrame(
            texture: pooled.texture, frameID: nextFrameID, timestamp: baseTimestamp + (clock.now - start),
            orientation: .up, colorConvention: .sRGBOpaque,
            readiness: .committed(on: renderer.commandQueue)
        )
        let lease = pool.lease(frame, using: pooled) { _ in }
        nextFrameID += 1
        let finished = clock.now

        let total = Self.milliseconds(finished - began)
        let report = Report(
            frameID: frame.frameID, pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scaleX,
            region: area, technique: used, wasScaledDown: effectiveScale < requested - 1e-9,
            drawMilliseconds: Self.milliseconds(drawn - began),
            uploadMilliseconds: Self.milliseconds(finished - drawn),
            totalMilliseconds: total, exceededBudget: total > configuration.budgetMilliseconds
        )
        captureCount += 1
        lastReport = report
        return (lease, report)
    }

    // MARK: Rendering

    /// Fills `context` with the opaque backdrop and draws `region` of `view`
    /// into it, upright, at the given scales.
    private func render(
        _ view: UIView, region: CGRect, into context: CGContext, scaleX: Double, scaleY: Double,
        technique: Technique, afterScreenUpdates: Bool
    ) throws(UIKitSnapshotError) -> Technique {
        let traits = view.traitCollection
        let backdrop = (configuration.backdrop ?? .systemBackground).resolvedColor(with: traits)
        func prepare() {
            context.saveGState()
            context.setBlendMode(.copy)
            context.setFillColor(backdrop.withAlphaComponent(1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            context.restoreGState()
        }

        let wantsHierarchy = technique == .drawHierarchy || (technique == .automatic && view.window != nil)
        if wantsHierarchy {
            prepare()
            if draw(view, region: region, into: context, scaleX: scaleX, scaleY: scaleY, hierarchy: true, afterScreenUpdates: afterScreenUpdates) {
                return .drawHierarchy
            }
            guard technique == .automatic else { throw .drawHierarchyFailed }
            // Automatic falls back to the layer tree, and says so in the report.
        }
        prepare()
        _ = draw(view, region: region, into: context, scaleX: scaleX, scaleY: scaleY, hierarchy: false, afterScreenUpdates: false)
        return .layerRender
    }

    /// One pass of drawing. `UIGraphicsPushContext` makes the bitmap UIKit's
    /// current context; the flip puts UIKit's origin at the top-left, which is
    /// the first row of the buffer and of the texture.
    private func draw(
        _ view: UIView, region: CGRect, into context: CGContext, scaleX: Double, scaleY: Double,
        hierarchy: Bool, afterScreenUpdates: Bool
    ) -> Bool {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: scaleX, y: -scaleY)
        // The view's bounds origin (a scroll view's content offset) maps to the
        // region's origin: the snapshot of the bounds is placed so that the
        // region starts at the buffer's top-left.
        let offset = CGPoint(x: view.bounds.minX - region.minX, y: view.bounds.minY - region.minY)
        var succeeded = true
        UIGraphicsPushContext(context)
        view.traitCollection.performAsCurrent {
            if hierarchy {
                succeeded = view.drawHierarchy(
                    in: CGRect(origin: offset, size: view.bounds.size), afterScreenUpdates: afterScreenUpdates
                )
            } else {
                context.translateBy(x: offset.x, y: offset.y)
                view.layer.render(in: context)
            }
        }
        UIGraphicsPopContext()
        return succeeded
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
#endif
