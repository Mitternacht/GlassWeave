import Metal
internal import GlassWeaveShaderTypes

/// Draws an explicit background source with rounded glass panels over it, in
/// a single render pass: none, one (``setPanel(_:)``), or an ordered list of
/// up to ``maximumPanelCount`` (``setPanels(_:)``).
///
/// Every panel samples the same frame, through the same
/// destination-to-source mapping and valid-rectangle clamp, as the background
/// it sits on, so no refraction can show a different frame than the
/// background around it. Without a panel the output is exactly the
/// background pass.
///
/// Each panel is drawn as one quad after the background, in list order. A
/// panel's quad covers its rectangle grown by one pixel and its glow's halo
/// radius (`GlassGlow.haloRadius`) on every side, and every pixel of it is
/// computed from the background sample, not from what an earlier panel drew:
/// where two quads overlap, the later panel wins. Lay panels out so that
/// their quads do not overlap; panels are not merged optically.
///
/// Source handling (validation, ordering, leases, defined skips) is the
/// ``BackgroundRenderer`` contract; this type adds the panel. Like that
/// renderer, it owns no display loop, never waits for the GPU, and is used
/// from one isolation domain at a time. Every pipeline (the background, and
/// the panel's ``PipelineVariant/base`` and ``PipelineVariant/optics``
/// variants) is built at initialization, never in the draw path.
public final class GlassRenderer {
    /// The render-target format: ``BackgroundRenderer/outputPixelFormat``.
    public static let outputPixelFormat = BackgroundRenderer.outputPixelFormat

    public let device: any MTLDevice
    /// The queue for every submission; see ``BackgroundRenderer/commandQueue``.
    public let commandQueue: any MTLCommandQueue

    private let background: BackgroundRenderer
    private let panelPipeline: any MTLRenderPipelineState
    /// The panel pipeline with the thick-lens code (GW-22), or `nil` when the
    /// panel library has no such variant (a frozen earlier shader).
    private let opticsPipeline: (any MTLRenderPipelineState)?

    /// The panel pipeline variants (GW-22), both built at initialization.
    public enum PipelineVariant: String, Hashable, Sendable {
        /// The shader without the thick-lens code: exactly the shader of
        /// GW-21. Draws every panel whose ``GlassParameters/lens`` is
        /// ``GlassLens/none``.
        case base
        /// The shader with the thick-lens code. Draws every panel whose lens
        /// has a profile other than ``GlassLens/Profile/rim``.
        case optics
    }

    /// The variant that drew each panel of the last draw that rendered any,
    /// in drawing order; empty before one. Panels that draw nothing (empty
    /// or outside the target) are not listed.
    public private(set) var drawnVariants: [PipelineVariant] = []

    /// How long initialization spent building the panel pipelines, in
    /// seconds.
    public let pipelineCreationSeconds: Double

    /// The most panels one draw renders. ``setPanels(_:)`` keeps the first
    /// this many, which bounds the work of a draw: each panel is one quad
    /// whose fragments evaluate the glass, its glow, and its interior.
    public static let maximumPanelCount = 8

    /// The panels as drawn, in drawing order: the last list passed to
    /// ``setPanels(_:)`` (or the one panel passed to ``setPanel(_:)``) after
    /// the ``GlassParameters`` normalization rule, at most
    /// ``maximumPanelCount`` of them. Empty for none.
    public private(set) var panels: [GlassPanel] = []

    /// The first panel as drawn, or `nil` for none. After ``setPanel(_:)``
    /// it is that panel, normalized.
    public var panel: GlassPanel? {
        panels.first
    }

    /// Records the CPU and GPU cost of every draw while set; `nil` (the
    /// default) measures nothing. See ``RenderMetrics``.
    public var metrics: RenderMetrics?

    /// The time on the effect clock, in seconds, at which draws evaluate
    /// animated glow (``GlassGlow/pulseLevel(at:)``). 0 until set.
    ///
    /// The renderer keeps no clock of its own: every draw is a function of
    /// its inputs, so a host advances this value from one time source per
    /// frame (`GlassSurfaceView` does, while a glow animates and the view is
    /// visible), and tests render chosen instants. Changing it does not
    /// request a draw.
    public private(set) var effectTime: Double = 0

    /// Sets the effect time for the following draws.
    ///
    /// Any finite value is accepted, including negative ones (the pulse is
    /// periodic). A non-finite value throws
    /// ``GlassParameterError/nonFinite(_:)`` naming
    /// ``GlassParameterError/Field/effectTime`` and leaves the time as it was.
    public func setEffectTime(_ seconds: Double) throws(GlassParameterError) {
        guard seconds.isFinite else { throw .nonFinite(.effectTime) }
        effectTime = seconds
    }

    /// Creates a renderer that submits to `commandQueue` on its device.
    /// Loads the package shader library and builds both pipelines now.
    public convenience init(commandQueue: any MTLCommandQueue) throws {
        let library = try BackgroundRenderer.makeLibrary(device: commandQueue.device)
        try self.init(
            commandQueue: commandQueue, library: library,
            panelLibrary: library, panelVertex: "gw_glass_vertex", panelFragment: "gw_glass_fragment"
        )
    }

    /// Creates a renderer whose panel pass uses the named functions from
    /// `panelLibrary`. The package uses its own glass shader; tests use this
    /// to draw with a frozen earlier version of it (the panel record's
    /// earlier layout is a prefix of the current one).
    init(
        commandQueue: any MTLCommandQueue, library: any MTLLibrary,
        panelLibrary: any MTLLibrary, panelVertex: String, panelFragment: String
    ) throws {
        let clock = ContinuousClock()
        let start = clock.now
        // A panel library with the function constant has two variants; a
        // frozen earlier shader has one.
        let hasOptics = panelLibrary.makeFunction(name: panelFragment)?
            .functionConstantsDictionary[Self.opticsConstantName] != nil
        panelPipeline = try Self.makePanelPipeline(
            device: commandQueue.device, library: panelLibrary, label: "GlassWeave glass panel",
            vertex: panelVertex, fragment: panelFragment, optics: hasOptics ? false : nil
        )
        opticsPipeline = hasOptics ? try Self.makePanelPipeline(
            device: commandQueue.device, library: panelLibrary, label: "GlassWeave glass panel (optics)",
            vertex: panelVertex, fragment: panelFragment, optics: true
        ) : nil
        let elapsed = clock.now - start
        pipelineCreationSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        background = try BackgroundRenderer(commandQueue: commandQueue, library: library)
        self.device = commandQueue.device
        self.commandQueue = commandQueue
    }

    /// The shader's name for the function constant that selects the variant.
    private static let opticsConstantName = "gw_optics_constant"

    /// Builds one variant of the panel pipeline. `optics` sets the shader's
    /// function constant; `nil` builds the function as it is (a library
    /// without the constant).
    private static func makePanelPipeline(
        device: any MTLDevice, library: any MTLLibrary, label: String,
        vertex: String, fragment: String, optics: Bool?
    ) throws -> any MTLRenderPipelineState {
        guard let optics else {
            return try BackgroundRenderer.makePipeline(
                device: device, library: library, label: label, vertex: vertex, fragment: fragment
            )
        }
        guard let vertexFunction = library.makeFunction(name: vertex) else {
            throw BackgroundRendererError.missingShaderFunction(vertex)
        }
        let constants = MTLFunctionConstantValues()
        var flag = optics
        constants.setConstantValue(&flag, type: .bool, index: 0)
        let fragmentFunction: any MTLFunction
        do {
            fragmentFunction = try library.makeFunction(name: fragment, constantValues: constants)
        } catch {
            throw BackgroundRendererError.pipelineCreationFailed("\(label): \(error)")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = BackgroundRenderer.outputPixelFormat
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw BackgroundRendererError.pipelineCreationFailed("\(label): \(error)")
        }
    }

    /// Sets the one panel to draw, or `nil` for the background alone. The
    /// same as ``setPanels(_:)`` with a list of that panel or an empty list.
    ///
    /// The panel is normalized by the documented rule: a non-finite value
    /// throws and leaves the current panels unchanged; finite out-of-range
    /// values are clamped. Read ``panel`` for the values actually drawn.
    public func setPanel(_ panel: GlassPanel?) throws(GlassParameterError) {
        try setPanels(panel.map { [$0] } ?? [])
    }

    /// Sets the panels to draw, in drawing order, or an empty list for the
    /// background alone.
    ///
    /// Every panel is normalized by the ``GlassParameters`` rule. A
    /// non-finite value in any panel of the list, including one past the
    /// maximum, throws ``GlassParameterError/nonFinite(_:)`` naming its
    /// field and leaves the current panels unchanged. Only the first
    /// ``maximumPanelCount`` panels are kept, as `GlassGlow` keeps its first
    /// four color stops. Read ``panels`` for the values actually drawn.
    public func setPanels(_ panels: [GlassPanel]) throws(GlassParameterError) {
        self.panels = try GlassPanel.normalized(panels)
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
        let panels = panels
        let effectTime = effectTime
        var variants: [PipelineVariant] = []
        let outcome = background.draw(targetPixelSize: targetPixelSize, commandBuffer: commandBuffer, acquireTarget: acquireTarget, onCommit: onCommit, overlay: { [panelPipeline, opticsPipeline] encoder, frame, backgroundUniforms, targetSize in
            // Converted only once a target exists, so the skips that run
            // before (including a zero display scale's zero-size target)
            // never see the scale.
            var textureSet = false
            var current: PipelineVariant?
            for panel in panels {
                let geometry = GlassPanelGeometry(panel: panel, displayScale: displayScale, effectTime: effectTime)
                guard !geometry.isEmpty else { continue }
                var uniforms = geometry.uniforms(
                    background: backgroundUniforms,
                    targetWidth: targetSize.width, targetHeight: targetSize.height
                )
                let length = MemoryLayout<GWGlassUniforms>.stride
                let uniformsIndex = Int(GWGlassBindingIndexUniforms.rawValue)
                // A lens needs the optics variant; a library without one
                // draws every panel with its only pipeline.
                let variant: PipelineVariant = geometry.lens != nil && opticsPipeline != nil ? .optics : .base
                encoder.pushDebugGroup("GlassWeave glass panel")
                if current != variant {
                    encoder.setRenderPipelineState(variant == .optics ? opticsPipeline ?? panelPipeline : panelPipeline)
                    current = variant
                }
                if !textureSet {
                    encoder.setFragmentTexture(frame.texture, index: Int(GWGlassBindingIndexSourceTexture.rawValue))
                    textureSet = true
                }
                encoder.setVertexBytes(&uniforms, length: length, index: uniformsIndex)
                encoder.setFragmentBytes(&uniforms, length: length, index: uniformsIndex)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.popDebugGroup()
                variants.append(variant)
            }
        })
        if !variants.isEmpty {
            drawnVariants = variants
        }
        return outcome
    }
}
