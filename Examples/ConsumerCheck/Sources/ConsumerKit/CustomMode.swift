import CoreGraphics
import GlassWeave
import Metal

/// Custom mode as a consumer uses it, without a view: the consumer owns the
/// device, queue, and producer; GlassWeave draws the background and one
/// panel into an offscreen target.
public final class OffscreenGlass {
    public let renderer: GlassRenderer
    public let metrics = RenderMetrics()
    private let pool: FrameTexturePool
    private var nextFrameID: UInt64 = 1

    public init(commandQueue: any MTLCommandQueue, panel: GlassPanel) throws {
        renderer = try GlassRenderer(commandQueue: commandQueue)
        try renderer.setPanel(panel)
        renderer.metrics = metrics
        pool = FrameTexturePool(
            device: commandQueue.device,
            descriptor: .init(
                pixelFormat: .bgra8Unorm,
                usage: [.renderTarget, .shaderRead, .pixelFormatView],
                sampledPixelFormat: BackgroundColorConvention.sRGBOpaque.requiredPixelFormat
            ),
            capacity: 3
        )
    }

    /// Produces a frame cleared to `color` and draws it with the panel into
    /// `target`, all in one command buffer.
    public func draw(
        background color: MTLClearColor,
        into target: any MTLTexture
    ) throws(BackgroundSourceError) -> BackgroundRenderOutcome {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        return try renderer.drawProducing(
            targetPixelSize: (target.width, target.height),
            displayScale: 1,
            produce: { commandBuffer, size in produce(color, into: commandBuffer, size: size) },
            acquireTarget: { BackgroundDrawTarget(renderPassDescriptor: pass) }
        )
    }

    private func produce(_ color: MTLClearColor, into commandBuffer: any MTLCommandBuffer, size: (width: Int, height: Int)) -> BackgroundFrameLease? {
        guard let pooled = pool.checkout(width: size.width, height: size.height) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = pooled.storage
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = color
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            pool.returnUnused(pooled)
            return nil
        }
        encoder.endEncoding()
        let frame = BackgroundFrame(
            texture: pooled.texture, frameID: nextFrameID, timestamp: .milliseconds(Int64(nextFrameID)),
            colorConvention: .sRGBOpaque, readiness: .encoded(in: commandBuffer)
        )
        nextFrameID += 1
        return pool.lease(frame, using: pooled) { _ in }
    }
}
