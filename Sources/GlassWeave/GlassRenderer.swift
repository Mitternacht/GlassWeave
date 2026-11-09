import CoreGraphics
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
/// A panel with grounding (``GlassParameters/grounding``, GW-25) adds a
/// pre-pass: after the background and before every panel body, one blended
/// quad per grounded panel multiplies its drop and contact shadows onto the
/// target and adds its caustic. Its body quad does not grow: the body leaves
/// every pixel outside its outline to the pre-pass, so a neighbour closer
/// than the shadow is long is never erased. Without a grounded panel nothing
/// extra is drawn.
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
    /// The panel pipeline with the thick-lens code and the light model
    /// (GW-23), or `nil` when the panel library has no such variant.
    private let lightingPipeline: (any MTLRenderPipelineState)?
    /// The panel pipeline with the grounding code (GW-25), blended over the
    /// target, and the two pre-pass pipelines (shadow multiply, caustic add);
    /// `nil` when the panel library has no such variant.
    private let groundedPipeline: (any MTLRenderPipelineState)?
    private let shadowPipeline: (any MTLRenderPipelineState)?
    private let causticPipeline: (any MTLRenderPipelineState)?
    /// The panel pipeline with every other variant's code and the freeform
    /// shape code (GW-26), blended like the grounded one, and the pre-pass
    /// pipelines that follow a shape; `nil` when the panel library has no such
    /// variant. A panel with a shape draws in these whatever else it draws:
    /// the lens, light model and grounding code is gated at run time by the
    /// panel's own record.
    private let shapedPipeline: (any MTLRenderPipelineState)?
    private let shapedShadowPipeline: (any MTLRenderPipelineState)?
    private let shapedCausticPipeline: (any MTLRenderPipelineState)?

    /// The panel pipeline variants (GW-22, GW-23, GW-25, GW-26), all built at
    /// initialization.
    public enum PipelineVariant: String, Hashable, Sendable {
        /// The shader without the thick-lens code: exactly the shader of
        /// GW-21. Draws every panel whose ``GlassParameters/lens`` is
        /// ``GlassLens/none``.
        case base
        /// The shader with the thick-lens code. Draws every panel whose lens
        /// has a profile other than ``GlassLens/Profile/rim``.
        case optics
        /// The shader with the thick-lens code and the light model
        /// (GW-23). Draws every panel whose ``GlassParameters/lighting`` is
        /// not ``GlassLighting/legacy``, with or without a lens.
        case lighting
        /// The shader with the thick-lens code, the light model, and the
        /// grounding code (GW-25), composited over the pre-pass by
        /// premultiplied alpha. Draws every panel whose
        /// ``GlassParameters/grounding`` is active.
        case grounded
        /// The shader with the thick-lens, light model and grounding code and
        /// the freeform shape code (GW-26). Draws every panel whose
        /// ``GlassParameters/shape`` is not ``GlassShape/roundedRectangle``,
        /// with any of the other effects.
        case shaped
    }

    /// How many pre-pass quads (a shadow quad or a caustic quad each) the last
    /// draw that rendered any panel encoded: 0 when no panel was grounded
    /// (GW-25).
    public private(set) var groundingDrawCount = 0

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

    /// The azimuth and elevation, in degrees, that following draws add to the
    /// key and rim lights of every panel whose ``GlassParameters/lighting``
    /// is not ``GlassLighting/legacy``; `(0, 0)` until set.
    public var lightOffset: (azimuth: Double, elevation: Double) {
        (offsetOfLight.azimuth, offsetOfLight.elevation)
    }

    private var offsetOfLight = GlassLightOffset()

    /// Moves the light for the following draws (GW-23): tilt, a dragged
    /// light, or a sweep. The offset is added to the key light's and the rim
    /// light's azimuth (degrees, any finite value) and elevation (degrees; the
    /// sum is clamped to 0...90), and it turns the studio and the glow's light
    /// angle with the key light. It changes only the light terms: nothing a
    /// panel draws without light depends on it. Changing it does not request
    /// a draw.
    ///
    /// A non-finite value throws ``GlassParameterError/nonFiniteLighting(_:)``
    /// naming ``GlassLighting/Field/lightOffsetAzimuth`` or
    /// ``GlassLighting/Field/lightOffsetElevation`` and leaves the offset as
    /// it was. Experimental.
    public func setLightOffset(azimuth: Double, elevation: Double) throws(GlassParameterError) {
        guard azimuth.isFinite else { throw .nonFiniteLighting(.lightOffsetAzimuth) }
        guard elevation.isFinite else { throw .nonFiniteLighting(.lightOffsetElevation) }
        offsetOfLight = GlassLightOffset(azimuth: GlassGlow.reducedAngle(azimuth), elevation: min(max(elevation, -90), 90))
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
    ///
    /// `opticsConstant` names the function constant (index 0) that selects the
    /// thick-lens variant in `panelLibrary`; a frozen shader keeps its own
    /// name for it.
    init(
        commandQueue: any MTLCommandQueue, library: any MTLLibrary,
        panelLibrary: any MTLLibrary, panelVertex: String, panelFragment: String,
        opticsConstant: String = GlassRenderer.opticsConstantName,
        lightingConstant: String = GlassRenderer.lightingConstantName,
        groundingConstant: String = GlassRenderer.groundingConstantName,
        shapeConstant: String = GlassRenderer.shapeConstantName,
        groundingFunctions: (vertex: String, shadow: String, caustic: String) = (
            GlassRenderer.groundingVertexName, GlassRenderer.groundingShadowName, GlassRenderer.groundingCausticName
        )
    ) throws {
        let clock = ContinuousClock()
        let start = clock.now
        // A panel library with the function constant has two variants; a
        // frozen earlier shader has one.
        let constants = panelLibrary.makeFunction(name: panelFragment)?.functionConstantsDictionary ?? [:]
        let hasOptics = constants[opticsConstant] != nil
        let hasLighting = hasOptics && constants[lightingConstant] != nil
        let hasGrounding = hasLighting && constants[groundingConstant] != nil
            && panelLibrary.makeFunction(name: groundingFunctions.vertex) != nil
        let hasShape = hasGrounding && constants[shapeConstant] != nil
        panelPipeline = try Self.makePanelPipeline(
            device: commandQueue.device, library: panelLibrary, label: "GlassWeave glass panel",
            vertex: panelVertex, fragment: panelFragment, optics: hasOptics ? false : nil, lighting: hasLighting ? false : nil,
            shape: hasShape ? false : nil
        )
        opticsPipeline = hasOptics ? try Self.makePanelPipeline(
            device: commandQueue.device, library: panelLibrary, label: "GlassWeave glass panel (optics)",
            vertex: panelVertex, fragment: panelFragment, optics: true, lighting: hasLighting ? false : nil,
            shape: hasShape ? false : nil
        ) : nil
        lightingPipeline = hasLighting ? try Self.makePanelPipeline(
            device: commandQueue.device, library: panelLibrary, label: "GlassWeave glass panel (lighting)",
            vertex: panelVertex, fragment: panelFragment, optics: true, lighting: true,
            shape: hasShape ? false : nil
        ) : nil
        groundedPipeline = hasGrounding ? try Self.makePanelPipeline(
            device: commandQueue.device, library: panelLibrary, label: "GlassWeave glass panel (grounded)",
            vertex: panelVertex, fragment: panelFragment, optics: true, lighting: true, grounding: true,
            shape: hasShape ? false : nil
        ) : nil
        shadowPipeline = hasGrounding ? try Self.makeGroundingPipeline(
            device: commandQueue.device, library: panelLibrary, label: "GlassWeave grounding shadow",
            vertex: groundingFunctions.vertex, fragment: groundingFunctions.shadow, multiply: true,
            shape: hasShape ? false : nil
        ) : nil
        causticPipeline = hasGrounding ? try Self.makeGroundingPipeline(
            device: commandQueue.device, library: panelLibrary, label: "GlassWeave grounding caustic",
            vertex: groundingFunctions.vertex, fragment: groundingFunctions.caustic, multiply: false,
            shape: hasShape ? false : nil
        ) : nil
        shapedPipeline = hasShape ? try Self.makePanelPipeline(
            device: commandQueue.device, library: panelLibrary, label: "GlassWeave glass panel (shaped)",
            vertex: panelVertex, fragment: panelFragment, optics: true, lighting: true, grounding: true, shape: true
        ) : nil
        shapedShadowPipeline = hasShape ? try Self.makeGroundingPipeline(
            device: commandQueue.device, library: panelLibrary, label: "GlassWeave grounding shadow (shaped)",
            vertex: groundingFunctions.vertex, fragment: groundingFunctions.shadow, multiply: true, shape: true
        ) : nil
        shapedCausticPipeline = hasShape ? try Self.makeGroundingPipeline(
            device: commandQueue.device, library: panelLibrary, label: "GlassWeave grounding caustic (shaped)",
            vertex: groundingFunctions.vertex, fragment: groundingFunctions.caustic, multiply: false, shape: true
        ) : nil
        let elapsed = clock.now - start
        pipelineCreationSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        background = try BackgroundRenderer(commandQueue: commandQueue, library: library)
        self.device = commandQueue.device
        self.commandQueue = commandQueue
    }

    /// The shader's name for the function constant that selects the variant.
    static let opticsConstantName = "gw_optics_constant"
    /// The shader's name for the function constant that adds the light model.
    static let lightingConstantName = "gw_lighting_constant"
    /// The shader's name for the function constant that adds the grounding.
    static let groundingConstantName = "gw_grounding_constant"
    /// The shader's name for the function constant that adds the freeform
    /// shapes.
    static let shapeConstantName = "gw_shape_constant"
    static let groundingVertexName = "gw_grounding_vertex"
    static let groundingShadowName = "gw_grounding_shadow_fragment"
    static let groundingCausticName = "gw_grounding_caustic_fragment"

    /// Builds one variant of the panel pipeline. `optics` and `lighting` set
    /// the shader's function constants; `nil` leaves a constant unset (a
    /// library without it), and `nil` for `optics` builds the function as it
    /// is.
    private static func makePanelPipeline(
        device: any MTLDevice, library: any MTLLibrary, label: String,
        vertex: String, fragment: String, optics: Bool?, lighting: Bool? = nil, grounding: Bool? = nil,
        shape: Bool? = nil
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
        if var lightingFlag = lighting {
            constants.setConstantValue(&lightingFlag, type: .bool, index: 1)
        }
        if var groundingFlag = grounding {
            constants.setConstantValue(&groundingFlag, type: .bool, index: 2)
        }
        if var shapeFlag = shape {
            constants.setConstantValue(&shapeFlag, type: .bool, index: 3)
        }
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
        if grounding == true {
            // The grounded body is composited over the pre-pass by
            // premultiplied alpha: `source + destination * (1 - source.a)`.
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw BackgroundRendererError.pipelineCreationFailed("\(label): \(error)")
        }
    }

    /// Builds one of the grounding's pre-pass pipelines (GW-25): the shadows
    /// multiply the target (`destination * source`), the caustic adds to it.
    /// Neither touches the target's alpha.
    private static func makeGroundingPipeline(
        device: any MTLDevice, library: any MTLLibrary, label: String, vertex: String, fragment: String, multiply: Bool,
        shape: Bool? = nil
    ) throws -> any MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: vertex) else {
            throw BackgroundRendererError.missingShaderFunction(vertex)
        }
        let fragmentFunction: any MTLFunction
        if var shapeFlag = shape {
            // The pre-pass functions read the shape constant: a rounded
            // rectangle's is set to false, a freeform shape's to true.
            let constants = MTLFunctionConstantValues()
            constants.setConstantValue(&shapeFlag, type: .bool, index: 3)
            do {
                fragmentFunction = try library.makeFunction(name: fragment, constantValues: constants)
            } catch {
                throw BackgroundRendererError.pipelineCreationFailed("\(label): \(error)")
            }
        } else {
            guard let plain = library.makeFunction(name: fragment) else {
                throw BackgroundRendererError.missingShaderFunction(fragment)
            }
            fragmentFunction = plain
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = BackgroundRenderer.outputPixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = multiply ? .zero : .one
        attachment.destinationRGBBlendFactor = multiply ? .sourceColor : .one
        attachment.sourceAlphaBlendFactor = .zero
        attachment.destinationAlphaBlendFactor = .one
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

    /// Two panels whose quads overlap (rule 10 of the optics study: panel
    /// quads must not overlap).
    package struct QuadOverlap: Equatable {
        /// The panels' indices in ``panels``, `first` below `second`.
        package var first: Int
        package var second: Int
        /// The overlapping rectangle, in target pixels.
        package var intersection: CGRect
    }

    /// The debug report of overlapping quads: every pair of panels (empty
    /// panels excluded) whose quads share area, in target pixels at
    /// `displayScale`. A panel's quad is its outline's bounding box grown by
    /// one pixel, the glow's halo, and the grounding's reach, as drawn. Where
    /// quads overlap the later panel wins and the earlier one's halo or shadow
    /// is cut; lay panels out so the report is empty. Every study asserts it
    /// is.
    package func overlappingQuads(displayScale: Double) -> [QuadOverlap] {
        guard displayScale.isFinite, displayScale > 0 else { return [] }
        let quads: [(index: Int, rect: CGRect)] = panels.enumerated().compactMap { index, panel in
            let geometry = GlassPanelGeometry(panel: panel, displayScale: displayScale)
            guard !geometry.isEmpty else { return nil }
            let reach = geometry.halfSize + geometry.quadOutset
            let origin = geometry.center - reach
            return (index, CGRect(x: origin.x, y: origin.y, width: reach.x * 2, height: reach.y * 2))
        }
        var overlaps: [QuadOverlap] = []
        for (position, first) in quads.enumerated() {
            for second in quads[(position + 1)...] {
                let shared = first.rect.intersection(second.rect)
                if !shared.isNull, shared.width > 0, shared.height > 0 {
                    overlaps.append(QuadOverlap(first: first.index, second: second.index, intersection: shared))
                }
            }
        }
        return overlaps
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
        let lightOffset = offsetOfLight
        var variants: [PipelineVariant] = []
        var groundingDraws = 0
        let outcome = background.draw(targetPixelSize: targetPixelSize, commandBuffer: commandBuffer, acquireTarget: acquireTarget, onCommit: onCommit, overlay: { [panelPipeline, opticsPipeline, lightingPipeline, groundedPipeline, shadowPipeline, causticPipeline, shapedPipeline, shapedShadowPipeline, shapedCausticPipeline] encoder, frame, backgroundUniforms, targetSize in
            // Converted only once a target exists, so the skips that run
            // before (including a zero display scale's zero-size target)
            // never see the scale.
            var textureSet = false
            var current: PipelineVariant?
            let length = MemoryLayout<GWGlassUniforms>.stride
            let uniformsIndex = Int(GWGlassBindingIndexUniforms.rawValue)
            let geometries = panels
                .map { GlassPanelGeometry(panel: $0, displayScale: displayScale, effectTime: effectTime, lightOffset: lightOffset) }
                .filter { !$0.isEmpty }
            // The grounding pre-pass (GW-25): every grounded panel's shadows
            // and caustic, before any body.
            if let shadowPipeline, let causticPipeline, groundedPipeline != nil {
                for geometry in geometries {
                    guard let grounding = geometry.grounding else { continue }
                    var uniforms = geometry.uniforms(
                        background: backgroundUniforms,
                        targetWidth: targetSize.width, targetHeight: targetSize.height
                    )
                    encoder.pushDebugGroup("GlassWeave grounding")
                    encoder.setVertexBytes(&uniforms, length: length, index: uniformsIndex)
                    encoder.setFragmentBytes(&uniforms, length: length, index: uniformsIndex)
                    // A panel with a shape casts a shadow of that shape.
                    let shaped = geometry.shape != nil && shapedPipeline != nil
                    if grounding.drawsShadow {
                        encoder.setRenderPipelineState(shaped ? shapedShadowPipeline ?? shadowPipeline : shadowPipeline)
                        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                        groundingDraws += 1
                    }
                    if grounding.drawsCaustic {
                        encoder.setRenderPipelineState(shaped ? shapedCausticPipeline ?? causticPipeline : causticPipeline)
                        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                        groundingDraws += 1
                    }
                    encoder.popDebugGroup()
                }
            }
            for geometry in geometries {
                var uniforms = geometry.uniforms(
                    background: backgroundUniforms,
                    targetWidth: targetSize.width, targetHeight: targetSize.height
                )
                // A lens needs the optics variant and the light model the
                // lighting variant; a library without one draws every panel
                // with its only pipeline.
                let variant: PipelineVariant = geometry.shape != nil && shapedPipeline != nil
                    ? .shaped
                    : (geometry.grounding != nil && groundedPipeline != nil
                        ? .grounded
                        : (geometry.lighting != nil && lightingPipeline != nil
                            ? .lighting : (geometry.lens != nil && opticsPipeline != nil ? .optics : .base)))
                encoder.pushDebugGroup("GlassWeave glass panel")
                if current != variant {
                    switch variant {
                    case .base: encoder.setRenderPipelineState(panelPipeline)
                    case .optics: encoder.setRenderPipelineState(opticsPipeline ?? panelPipeline)
                    case .lighting: encoder.setRenderPipelineState(lightingPipeline ?? panelPipeline)
                    case .grounded: encoder.setRenderPipelineState(groundedPipeline ?? panelPipeline)
                    case .shaped: encoder.setRenderPipelineState(shapedPipeline ?? panelPipeline)
                    }
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
            groundingDrawCount = groundingDraws
        }
        return outcome
    }
}
