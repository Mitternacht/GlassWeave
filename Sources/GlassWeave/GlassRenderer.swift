import Metal
internal import GlassWeaveShaderTypes

/// Draws an explicit background source with one optional rounded glass
/// panel over it, in a single render pass.
///
/// The panel samples the same frame, through the same destination-to-source
/// mapping and valid-rectangle clamp, as the background it sits on, so the
/// refraction can never show a different frame than the background around
/// it. Without a panel the output is exactly the background pass.
///
/// Source handling (validation, ordering, leases, defined skips) is the
/// ``BackgroundRenderer`` contract; this type adds the panel. Like that
/// renderer, it owns no display loop, never waits for the GPU, and is used
/// from one isolation domain at a time. Both pipelines are built at
/// initialization, never in the draw path.
public final class GlassRenderer {
    /// The render-target format: ``BackgroundRenderer/outputPixelFormat``.
    public static let outputPixelFormat = BackgroundRenderer.outputPixelFormat

    public let device: any MTLDevice
    /// The queue for every submission; see ``BackgroundRenderer/commandQueue``.
    public let commandQueue: any MTLCommandQueue

    private let background: BackgroundRenderer
    private let panelPipeline: any MTLRenderPipelineState

    /// The panel as drawn: the last panel passed to ``setPanel(_:)`` after
    /// the ``GlassParameters`` normalization rule, or `nil` for none.
    public private(set) var panel: GlassPanel?

    /// Records the CPU and GPU cost of every draw while set; `nil` (the
    /// default) measures nothing. See ``RenderMetrics``.
    public var metrics: RenderMetrics?

    /// Creates a renderer that submits to `commandQueue` on its device.
    /// Loads the package shader library and builds both pipelines now.
    public init(commandQueue: any MTLCommandQueue) throws {
        let library = try BackgroundRenderer.makeLibrary(device: commandQueue.device)
        panelPipeline = try BackgroundRenderer.makePipeline(
            device: commandQueue.device, library: library, label: "GlassWeave glass panel",
            vertex: "gw_glass_vertex", fragment: "gw_glass_fragment"
        )
        background = try BackgroundRenderer(commandQueue: commandQueue, library: library)
        self.device = commandQueue.device
        self.commandQueue = commandQueue
    }

    /// Sets the panel to draw, or `nil` for the background alone.
    ///
    /// The panel is normalized by the documented rule: a non-finite value
    /// throws and leaves the current panel unchanged; finite out-of-range
    /// values are clamped. Read ``panel`` for the values actually drawn.
    public func setPanel(_ panel: GlassPanel?) throws(GlassParameterError) {
        self.panel = try panel?.normalized()
    }

    /// The frame currently presented, if any.
    public var currentFrame: BackgroundFrame? {
        background.currentFrame
    }

    /// Validates and attaches a source; see ``BackgroundRenderer/setSource(_:)``.
    public func setSource(_ lease: BackgroundFrameLease) throws(BackgroundSourceError) {
        try background.setSource(lease)
    }

    /// Detaches the source; see ``BackgroundRenderer/clearSource()``.
    public func clearSource() {
        background.clearSource()
    }

    /// Draws the background and the panel into a target the host provides
    /// on demand.
    ///
    /// The defined skips and their order are those of
    /// ``BackgroundRenderer/draw(targetPixelSize:acquireTarget:)``. An
    /// empty panel draws nothing over the background.
    ///
    /// - Parameters:
    ///   - targetPixelSize: The size the host expects the target to have.
    ///   - displayScale: Pixels per point, used to convert the panel from
    ///     points. Must be finite and positive.
    ///   - acquireTarget: Called at most once, after the checks pass.
    public func draw(
        targetPixelSize: (width: Int, height: Int),
        displayScale: Double,
        acquireTarget: () -> BackgroundDrawTarget?
    ) -> BackgroundRenderOutcome {
        draw(targetPixelSize: targetPixelSize, displayScale: displayScale, acquireTarget: acquireTarget, onCommit: { _ in })
    }

    /// ``draw(targetPixelSize:displayScale:acquireTarget:)`` that also hands
    /// the host each command buffer just before it is committed, so the host
    /// can bound and track frames in flight.
    package func draw(
        targetPixelSize: (width: Int, height: Int),
        displayScale: Double,
        acquireTarget: () -> BackgroundDrawTarget?,
        onCommit: (any MTLCommandBuffer) -> Void
    ) -> BackgroundRenderOutcome {
        let timer = DrawTimer(metrics: metrics)
        let outcome = draw(
            targetPixelSize: targetPixelSize, displayScale: displayScale, commandBuffer: nil,
            acquireTarget: { timer.acquire(acquireTarget) },
            onCommit: { [device] commandBuffer, frameID, drewFrame in
                timer.willCommit(commandBuffer, frameID: frameID, drewFrame: drewFrame, device: device)
                onCommit(commandBuffer)
            }
        )
        timer.finish(outcome)
        return outcome
    }

    /// Produces a new source frame and draws it, in one command buffer.
    ///
    /// The renderer makes a command buffer on its queue and calls `produce`
    /// with it and the target size. The producer encodes its writes into that
    /// command buffer and returns a lease whose frame declares
    /// ``BackgroundFrameReadiness/encoded(in:)`` with the same command
    /// buffer. The renderer then attaches the frame, encodes the background
    /// and panel *later in the same command buffer*, so Metal orders the
    /// sampling after the writes, and commits it once. The background and the
    /// refraction therefore always show the frame produced for this draw.
    ///
    /// Ownership: the renderer takes over the producer's hold and retires it
    /// once the frame is attached, so do not hand the lease to another
    /// consumer. The release still waits for every use, including the
    /// command buffer that carries the writes.
    ///
    /// `produce` may return `nil` to produce nothing this time (for example,
    /// when no reusable texture is free); it must then encode nothing. The
    /// renderer draws the current source instead.
    ///
    /// Defined skips are those of ``draw(targetPixelSize:displayScale:acquireTarget:)``.
    /// A zero-size target skips before `produce` is called. When a frame was
    /// produced but no drawable is available, the frame still becomes current
    /// and its writes are committed, so a later draw can show it.
    ///
    /// - Throws: ``BackgroundSourceError`` if the produced frame breaks the
    ///   source contract. Its writes are still committed, its producer hold
    ///   is retired once they complete, and the previous source stays.
    public func drawProducing(
        targetPixelSize: (width: Int, height: Int),
        displayScale: Double,
        produce: (_ commandBuffer: any MTLCommandBuffer, _ pixelSize: (width: Int, height: Int)) -> BackgroundFrameLease?,
        acquireTarget: () -> BackgroundDrawTarget?
    ) throws(BackgroundSourceError) -> BackgroundRenderOutcome {
        try drawProducing(targetPixelSize: targetPixelSize, displayScale: displayScale, produce: produce, acquireTarget: acquireTarget, onCommit: { _ in })
    }

    /// ``drawProducing(targetPixelSize:displayScale:produce:acquireTarget:)``
    /// that also hands the host the command buffer just before it is
    /// committed, on every path that commits it (including a rejected frame).
    package func drawProducing(
        targetPixelSize: (width: Int, height: Int),
        displayScale: Double,
        produce: (_ commandBuffer: any MTLCommandBuffer, _ pixelSize: (width: Int, height: Int)) -> BackgroundFrameLease?,
        acquireTarget: () -> BackgroundDrawTarget?,
        onCommit: (any MTLCommandBuffer) -> Void
    ) throws(BackgroundSourceError) -> BackgroundRenderOutcome {
        let timer = DrawTimer(metrics: metrics)
        do throws(BackgroundSourceError) {
            let outcome = try produceAndDraw(
                targetPixelSize: targetPixelSize, displayScale: displayScale,
                produce: { commandBuffer, pixelSize in timer.produce { produce(commandBuffer, pixelSize) } },
                acquireTarget: { timer.acquire(acquireTarget) },
                onCommit: { [device] commandBuffer, frameID, drewFrame in
                    timer.willCommit(commandBuffer, frameID: frameID, drewFrame: drewFrame, device: device)
                    onCommit(commandBuffer)
                }
            )
            timer.finish(outcome)
            return outcome
        } catch {
            timer.finish(nil)
            throw error
        }
    }

    /// The production path behind both `drawProducing` methods.
    private func produceAndDraw(
        targetPixelSize: (width: Int, height: Int),
        displayScale: Double,
        produce: (_ commandBuffer: any MTLCommandBuffer, _ pixelSize: (width: Int, height: Int)) -> BackgroundFrameLease?,
        acquireTarget: () -> BackgroundDrawTarget?,
        onCommit: (_ commandBuffer: any MTLCommandBuffer, _ frameID: UInt64, _ drewFrame: Bool) -> Void
    ) throws(BackgroundSourceError) -> BackgroundRenderOutcome {
        guard targetPixelSize.width > 0, targetPixelSize.height > 0 else {
            return .skipped(.zeroSizeTarget)
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return .skipped(.encoderUnavailable)
        }
        if let lease = produce(commandBuffer, targetPixelSize) {
            commandBuffer.label = "GlassWeave produced frame \(lease.frame.frameID)"
            do {
                try background.setSource(lease, drawCommandBuffer: commandBuffer)
            } catch {
                // Let the producer's writes finish before it may reuse them.
                let core = lease.core
                commandBuffer.addCompletedHandler { _ in core.retireProducer() }
                onCommit(commandBuffer, lease.frame.frameID, false)
                commandBuffer.commit()
                throw error
            }
            lease.retire()
        }
        return draw(targetPixelSize: targetPixelSize, displayScale: displayScale, commandBuffer: commandBuffer, acquireTarget: acquireTarget, onCommit: onCommit)
    }

    private func draw(
        targetPixelSize: (width: Int, height: Int),
        displayScale: Double,
        commandBuffer: (any MTLCommandBuffer)?,
        acquireTarget: () -> BackgroundDrawTarget?,
        onCommit: (_ commandBuffer: any MTLCommandBuffer, _ frameID: UInt64, _ drewFrame: Bool) -> Void
    ) -> BackgroundRenderOutcome {
        let panel = panel
        return background.draw(targetPixelSize: targetPixelSize, commandBuffer: commandBuffer, acquireTarget: acquireTarget, onCommit: onCommit, overlay: { [panelPipeline] encoder, frame, backgroundUniforms, targetSize in
            // Converted only once a target exists, so the skips that run
            // before (including a zero display scale's zero-size target)
            // never see the scale.
            guard let panel else { return }
            let geometry = GlassPanelGeometry(panel: panel, displayScale: displayScale)
            guard !geometry.isEmpty else { return }
            var uniforms = geometry.uniforms(
                background: backgroundUniforms,
                targetWidth: targetSize.width, targetHeight: targetSize.height
            )
            let length = MemoryLayout<GWGlassUniforms>.stride
            let uniformsIndex = Int(GWGlassBindingIndexUniforms.rawValue)
            encoder.pushDebugGroup("GlassWeave glass panel")
            encoder.setRenderPipelineState(panelPipeline)
            encoder.setVertexBytes(&uniforms, length: length, index: uniformsIndex)
            encoder.setFragmentBytes(&uniforms, length: length, index: uniformsIndex)
            encoder.setFragmentTexture(frame.texture, index: Int(GWGlassBindingIndexSourceTexture.rawValue))
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.popDebugGroup()
        })
    }
}
