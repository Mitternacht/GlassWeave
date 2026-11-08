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
        let panel = panel
        return background.draw(targetPixelSize: targetPixelSize, acquireTarget: acquireTarget, overlay: { [panelPipeline] encoder, frame, backgroundUniforms, targetSize in
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
