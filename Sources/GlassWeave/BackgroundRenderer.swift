import Metal
import os
import Synchronization
internal import GlassWeaveShaderTypes

/// Why a draw produced no GPU work. Each is a transient, defined skip, not a
/// library failure; the caller decides what fallback to show.
public enum BackgroundRenderSkipReason: Hashable, Sendable {
    /// No source frame is attached.
    case missingSource
    /// The target has zero pixels in at least one dimension.
    case zeroSizeTarget
    /// The host could not provide a drawable or render target this time.
    case drawableUnavailable
    /// The current source's lease was released, so it can no longer be sampled.
    case sourceReleased
    /// Metal could not create a command buffer or render encoder.
    case encoderUnavailable
}

/// The result of one draw request.
public enum BackgroundRenderOutcome: Hashable, Sendable {
    /// Rendering of the frame was committed to the GPU.
    case submitted(frameID: UInt64)
    /// Nothing was committed; see the reason.
    case skipped(BackgroundRenderSkipReason)
}

/// A render target supplied by the host at the last moment.
public struct BackgroundDrawTarget {
    /// The pass to render into. Its first color attachment must use
    /// ``BackgroundRenderer/outputPixelFormat``.
    public var renderPassDescriptor: MTLRenderPassDescriptor
    /// The drawable to present after encoding, if the target is on screen.
    public var drawable: (any MTLDrawable)?

    public init(renderPassDescriptor: MTLRenderPassDescriptor, drawable: (any MTLDrawable)? = nil) {
        self.renderPassDescriptor = renderPassDescriptor
        self.drawable = drawable
    }
}

/// Failures while preparing a renderer. Pipelines are built once, here, and
/// never in the draw path.
public enum BackgroundRendererError: Error, CustomStringConvertible {
    case shaderLibraryUnavailable(String)
    case missingShaderFunction(String)
    case pipelineCreationFailed(String)

    public var description: String {
        switch self {
        case let .shaderLibraryUnavailable(reason):
            "GlassWeave's shader library could not be loaded: \(reason). Build the package with Xcode so its Metal shaders are compiled."
        case let .missingShaderFunction(name):
            "GlassWeave's shader library has no function named \(name). Rebuild the package."
        case let .pipelineCreationFailed(reason):
            "A GlassWeave render pipeline could not be created: \(reason)."
        }
    }
}

/// Presents an explicit, app-owned background source into a render target.
///
/// One renderer serves one host surface. It owns a render pipeline built at
/// initialization, the current source frame, and its lease hold. It does not
/// own a display loop: the host asks it to draw when something changed.
///
/// Use a renderer from one isolation domain at a time (a UIKit host uses it
/// on the main actor). It never waits for GPU completion.
public final class BackgroundRenderer {
    /// The render-target format the pipeline writes: non-sRGB 8-bit BGRA
    /// holding sRGB-encoded values. The shader samples sources in linear
    /// light and encodes explicitly, because the iOS Simulator cannot write
    /// to sRGB textures.
    public static let outputPixelFormat: MTLPixelFormat = .bgra8Unorm

    public let device: any MTLDevice
    /// The queue for every submission. Producers must commit their writes to
    /// this queue before handing over a frame (same-queue readiness).
    public let commandQueue: any MTLCommandQueue

    private let pipeline: any MTLRenderPipelineState
    private var source: (lease: BackgroundFrameLease, hold: LeaseHold)?
    private var lastAccepted: (frameID: UInt64, timestamp: Duration)?

    /// Creates a renderer that submits to `commandQueue` on its device.
    /// Loads the package shader library and builds the pipeline now.
    public convenience init(commandQueue: any MTLCommandQueue) throws {
        try self.init(commandQueue: commandQueue, library: Self.makeLibrary(device: commandQueue.device))
    }

    /// Creates a renderer from an already loaded package shader library.
    init(commandQueue: any MTLCommandQueue, library: any MTLLibrary) throws {
        pipeline = try Self.makePipeline(
            device: commandQueue.device, library: library, label: "GlassWeave background",
            vertex: "gw_background_vertex", fragment: "gw_background_fragment"
        )
        self.device = commandQueue.device
        self.commandQueue = commandQueue
        RendererCensus.recordCreation()
    }

    /// Loads the package's compiled shader library.
    static func makeLibrary(device: any MTLDevice) throws -> any MTLLibrary {
        do {
            return try device.makeDefaultLibrary(bundle: .module)
        } catch {
            throw BackgroundRendererError.shaderLibraryUnavailable(String(describing: error))
        }
    }

    /// Builds a render pipeline that writes ``outputPixelFormat``.
    static func makePipeline(
        device: any MTLDevice, library: any MTLLibrary, label: String,
        vertex: String, fragment: String
    ) throws -> any MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: vertex) else {
            throw BackgroundRendererError.missingShaderFunction(vertex)
        }
        guard let fragmentFunction = library.makeFunction(name: fragment) else {
            throw BackgroundRendererError.missingShaderFunction(fragment)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = outputPixelFormat
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw BackgroundRendererError.pipelineCreationFailed("\(label): \(error)")
        }
    }

    deinit {
        source?.hold.endPresentation()
        RendererCensus.recordDestruction()
    }

    /// The frame currently presented, if any.
    public var currentFrame: BackgroundFrame? {
        source?.lease.frame
    }

    /// Validates `lease`'s frame against the source contract and makes it the
    /// current source, ending the hold on the previous one.
    ///
    /// Attaching the lease already current is a no-op. On error, the
    /// previous source stays current.
    public func setSource(_ lease: BackgroundFrameLease) throws(BackgroundSourceError) {
        try setSource(lease, drawCommandBuffer: nil)
    }

    /// Validates and attaches a source. `drawCommandBuffer` is the command
    /// buffer of the draw in progress: a frame whose writes were encoded in
    /// it is ordered by being sampled later in the same command buffer.
    func setSource(
        _ lease: BackgroundFrameLease,
        drawCommandBuffer: (any MTLCommandBuffer)?
    ) throws(BackgroundSourceError) {
        if let source, source.lease === lease { return }
        let frame = lease.frame
        try SourceFrameValidation.validate(
            texture: SourceTextureFacts(frame.texture),
            colorConvention: frame.colorConvention,
            validRect: frame.validRect,
            readinessQueue: frame.readiness.queueIdentity,
            rendererDevice: ObjectIdentifier(device),
            rendererDeviceName: device.name,
            rendererQueue: ObjectIdentifier(commandQueue)
        )
        if let writes = frame.readiness.encodingCommandBuffer,
           writes !== drawCommandBuffer, writes.status == .notEnqueued {
            throw .commandBufferNotEnqueued
        }
        try SourceFrameValidation.validateOrder(
            frameID: frame.frameID, timestamp: frame.timestamp, after: lastAccepted
        )
        guard let hold = lease.core.acquire(.presentation) else {
            throw .leaseAlreadyReleased(frameID: frame.frameID)
        }
        let previous = source
        source = (lease, hold)
        lastAccepted = (frame.frameID, frame.timestamp)
        previous?.hold.endPresentation()
    }

    /// Detaches the current source and ends its presentation hold. Frame
    /// ordering continues: a later source must still have a greater ID.
    public func clearSource() {
        let previous = source
        source = nil
        previous?.hold.endPresentation()
    }

    /// Draws the current source into a target the host provides on demand.
    ///
    /// Checks run before the target is requested, so a missing source or a
    /// zero-size target never acquires a drawable. `acquireTarget` returning
    /// `nil` is a defined skip. The method commits without waiting.
    ///
    /// - Parameters:
    ///   - targetPixelSize: The size the host expects the target to have.
    ///   - acquireTarget: Called at most once, after the checks pass.
    public func draw(
        targetPixelSize: (width: Int, height: Int),
        acquireTarget: () -> BackgroundDrawTarget?
    ) -> BackgroundRenderOutcome {
        draw(targetPixelSize: targetPixelSize, acquireTarget: acquireTarget, overlay: nil)
    }

    /// Work a composing renderer encodes after the background, in the same
    /// render pass, reading the same frame through the same mapping.
    typealias Overlay = (
        _ encoder: any MTLRenderCommandEncoder,
        _ frame: BackgroundFrame,
        _ background: GWBackgroundUniforms,
        _ targetSize: (width: Int, height: Int)
    ) -> Void

    /// Draws the background, then `overlay`, into one render pass.
    ///
    /// - Parameter provided: A command buffer that already carries the
    ///   current frame's writes (a produced frame). It is committed on every
    ///   path that gets past the source checks, so the writes always run,
    ///   and a skipped use ends only when it completes, so the producer
    ///   never hears "reusable" while its writes are in flight.
    /// - Parameter onCommit: Called with each command buffer just before
    ///   this draw commits it, so a host can track the frame until it
    ///   completes, with the frame's ID and whether the command buffer drew
    ///   it (`false` when it only carries a produced frame's writes). Not
    ///   called when the draw commits nothing.
    func draw(
        targetPixelSize: (width: Int, height: Int),
        commandBuffer provided: (any MTLCommandBuffer)? = nil,
        acquireTarget: () -> BackgroundDrawTarget?,
        onCommit: (_ commandBuffer: any MTLCommandBuffer, _ frameID: UInt64, _ drewFrame: Bool) -> Void = { _, _, _ in },
        overlay: Overlay?
    ) -> BackgroundRenderOutcome {
        guard let source else { return .skipped(.missingSource) }
        guard targetPixelSize.width > 0, targetPixelSize.height > 0 else {
            return .skipped(.zeroSizeTarget)
        }
        guard let submission = source.lease.core.acquire(.submission) else {
            return .skipped(.sourceReleased)
        }
        /// Ends a use that drew nothing, after any provided writes finish.
        func endWithoutDrawing(_ outcome: LeaseHold.SubmissionEnd) {
            guard let provided else {
                submission.end(outcome)
                return
            }
            provided.addCompletedHandler { _ in submission.end(outcome) }
            onCommit(provided, source.lease.frame.frameID, false)
            provided.commit()
        }
        guard let target = acquireTarget(),
              let colorTexture = target.renderPassDescriptor.colorAttachments[0].texture
        else {
            endWithoutDrawing(.skipped)
            return .skipped(.drawableUnavailable)
        }
        precondition(
            colorTexture.pixelFormat == Self.outputPixelFormat,
            "GlassWeave renders into \(BackgroundSourceError.name(of: Self.outputPixelFormat)) targets; configure the host view's color format accordingly"
        )
        // Retained references keep the source texture alive until this
        // command buffer completes, independent of the lease object.
        guard let commandBuffer = provided ?? commandQueue.makeCommandBuffer() else {
            endWithoutDrawing(.cancelled)
            return .skipped(.encoderUnavailable)
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: target.renderPassDescriptor) else {
            endWithoutDrawing(.cancelled)
            return .skipped(.encoderUnavailable)
        }
        let frame = source.lease.frame
        if provided == nil {
            commandBuffer.label = "GlassWeave background frame \(frame.frameID)"
        }
        var uniforms = SourceUVTransform(
            destinationWidth: colorTexture.width,
            destinationHeight: colorTexture.height,
            frame: frame
        ).uniforms
        encoder.label = "GlassWeave background"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<GWBackgroundUniforms>.stride,
            index: Int(GWBackgroundBindingIndexUniforms.rawValue)
        )
        encoder.setFragmentTexture(frame.texture, index: Int(GWBackgroundBindingIndexSourceTexture.rawValue))
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        overlay?(encoder, frame, uniforms, (colorTexture.width, colorTexture.height))
        encoder.endEncoding()
        if let drawable = target.drawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.addCompletedHandler { commandBuffer in
            submission.end(commandBuffer.status == .completed ? .completed : .failed)
        }
        onCommit(commandBuffer, frame.frameID, true)
        commandBuffer.commit()
        return .submitted(frameID: frame.frameID)
    }
}

/// Counts GlassWeave renderers so tests and traces can show which code paths
/// create GPU objects.
///
/// A renderer is the only GlassWeave object that builds a pipeline or
/// submits GPU work, and the only `MTKView` host (`GlassSurfaceView`) needs
/// one. Every renderer is a `BackgroundRenderer` or contains exactly one
/// (a `GlassRenderer` builds its panel pipeline in the same initializer), so
/// counting `BackgroundRenderer` creations counts renderers. GlassWeave
/// never creates a Metal device or command queue itself; the app passes its
/// queue to a renderer. So a code path that creates no renderer creates no
/// GlassWeave GPU objects and runs no render loop.
///
/// Each creation and destruction also emits an `os_signpost` event in the
/// "dev.glassweave" subsystem, "Renderer" category, visible in Instruments'
/// os_signpost and Points of Interest tracks.
enum RendererCensus {
    private static let createdCount = Atomic<Int>(0)
    private static let liveCount = Atomic<Int>(0)
    private static let signposter = OSSignposter(subsystem: "dev.glassweave", category: "Renderer")

    /// Renderers created since the process started.
    static var created: Int { createdCount.load(ordering: .relaxed) }
    /// Renderers currently alive.
    static var live: Int { liveCount.load(ordering: .relaxed) }

    /// Counts the renderers created while one task runs an operation, so a
    /// check is not disturbed by renderers that concurrent work creates.
    final class Scope: Sendable {
        private let count = Atomic<Int>(0)

        init() {}

        /// Renderers created inside this scope so far.
        var created: Int { count.load(ordering: .relaxed) }

        fileprivate func record() {
            count.wrappingAdd(1, ordering: .relaxed)
        }
    }

    @TaskLocal static var scope: Scope?

    /// Runs `operation` and reports how many renderers it created on the
    /// calling task, including from synchronous UIKit callbacks it triggers.
    static func counting<Result>(_ operation: () throws -> Result) rethrows -> (result: Result, created: Int) {
        let scope = Scope()
        let result = try $scope.withValue(scope) { try operation() }
        return (result, scope.created)
    }

    static func recordCreation() {
        createdCount.wrappingAdd(1, ordering: .relaxed)
        liveCount.wrappingAdd(1, ordering: .relaxed)
        scope?.record()
        signposter.emitEvent("BackgroundRenderer created")
    }

    static func recordDestruction() {
        liveCount.wrappingSubtract(1, ordering: .relaxed)
        signposter.emitEvent("BackgroundRenderer destroyed")
    }
}
