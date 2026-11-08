import CoreGraphics
import Metal
import Testing
@testable import GlassWeave

/// Frames produced inside the draw's own command buffer: the writes are
/// encoded first, the background and panel sample them later in the same
/// command buffer, and the lease is released only after that work runs.
@Suite(.timeLimit(.minutes(1)))
struct ProducedFrameTests {
    private static let panel = GlassPanel(
        frame: CGRect(x: 8, y: 6, width: 48, height: 36),
        parameters: GlassParameters(cornerRadius: 10, bezelWidth: 12, refraction: 1, edgeHighlight: 0)
    )

    /// Encodes a clear of a new texture to `color` (sRGB-encoded bytes) into
    /// `commandBuffer` and returns its lease. Like the laboratory's producer,
    /// it renders into a `bgra8Unorm` texture (the Simulator cannot write
    /// sRGB textures) and hands over a `bgra8Unorm_srgb` view of it.
    private func encodeClear(
        _ gpu: GPUContext, into commandBuffer: any MTLCommandBuffer,
        width: Int, height: Int, color: (UInt8, UInt8, UInt8), frameID: UInt64,
        onRelease: @escaping @Sendable (BackgroundFrameRelease) -> Void = { _ in }
    ) throws -> BackgroundFrameLease {
        let storage = try gpu.makeTexture(
            width: width, height: height, pixelFormat: .bgra8Unorm,
            usage: [.renderTarget, .shaderRead, .pixelFormatView]
        )
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = storage
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(color.0) / 255, green: Double(color.1) / 255, blue: Double(color.2) / 255, alpha: 1
        )
        let encoder = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.endEncoding()
        let view = try #require(storage.makeTextureView(pixelFormat: .bgra8Unorm_srgb))
        let frame = BackgroundFrame(
            texture: view, frameID: frameID, timestamp: .milliseconds(Int64(frameID) * 16),
            colorConvention: .sRGBOpaque, readiness: .encoded(in: commandBuffer)
        )
        return BackgroundFrameLease(frame: frame, onRelease: onRelease)
    }

    private func everyPixel(_ image: RenderedImage, is color: (UInt8, UInt8, UInt8)) -> Bool {
        (0..<image.height).allSatisfy { y in
            (0..<image.width).allSatisfy { x in
                image.channels(x: x, y: y).largestDifference(from: SIMD3(Double(color.2), Double(color.1), Double(color.0))) <= 1
            }
        }
    }

    @Test func `Background and panel show the frame produced in the same command buffer`() async throws {
        let gpu = try GPUContext()
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        try renderer.setPanel(Self.panel)
        let recorder = ReleaseRecorder()
        // Each draw produces a differently colored frame; every pixel, inside
        // the panel and out, must show the frame produced for that draw.
        let colors: [(UInt8, UInt8, UInt8)] = [(200, 40, 30), (20, 180, 60), (40, 60, 220)]
        for (index, color) in colors.enumerated() {
            let frameID = UInt64(index + 1)
            let target = try gpu.makeTarget(width: 64, height: 48)
            var producedWidth = 0, producedHeight = 0
            let outcome = try renderer.drawProducing(targetPixelSize: (64, 48), displayScale: 1, produce: { commandBuffer, size in
                (producedWidth, producedHeight) = size
                return try? encodeClear(gpu, into: commandBuffer, width: size.width, height: size.height, color: color, frameID: frameID, onRelease: recorder.handler)
            }, acquireTarget: { target })
            #expect(outcome == .submitted(frameID: frameID))
            #expect(producedWidth == 64 && producedHeight == 48)
            #expect(renderer.currentFrame?.frameID == frameID)
            let image = try await gpu.readBack(try #require(target.renderPassDescriptor.colorAttachments[0].texture))
            #expect(image.isFullyOpaque)
            #expect(everyPixel(image, is: color), "frame \(frameID)")
        }
        renderer.clearSource()
        // Each frame is released once, after its single draw completed.
        while recorder.releases.count < colors.count {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(recorder.releases.map(\.frameID).sorted() == [1, 2, 3])
        #expect(recorder.releases.allSatisfy { $0.completedSubmissions == 1 && $0.skippedSubmissions == 0 })
    }

    @Test func `Producing nothing redraws the current frame`() async throws {
        let gpu = try GPUContext()
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        try renderer.setPanel(Self.panel)
        let first = try gpu.makeTarget(width: 64, height: 48)
        _ = try renderer.drawProducing(targetPixelSize: (64, 48), displayScale: 1, produce: { commandBuffer, size in
            try? encodeClear(gpu, into: commandBuffer, width: size.width, height: size.height, color: (90, 120, 150), frameID: 1)
        }, acquireTarget: { first })
        let second = try gpu.makeTarget(width: 64, height: 48)
        let outcome = try renderer.drawProducing(targetPixelSize: (64, 48), displayScale: 1, produce: { _, _ in nil }, acquireTarget: { second })
        #expect(outcome == .submitted(frameID: 1))
        let image = try await gpu.readBack(try #require(second.renderPassDescriptor.colorAttachments[0].texture))
        #expect(everyPixel(image, is: (90, 120, 150)))
    }

    @Test func `A produced frame without a drawable is still written and kept`() async throws {
        let gpu = try GPUContext()
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        let recorder = ReleaseRecorder()
        let outcome = try renderer.drawProducing(targetPixelSize: (32, 32), displayScale: 1, produce: { commandBuffer, size in
            try? encodeClear(gpu, into: commandBuffer, width: size.width, height: size.height, color: (250, 200, 10), frameID: 1, onRelease: recorder.handler)
        }, acquireTarget: { nil })
        #expect(outcome == .skipped(.drawableUnavailable))
        #expect(renderer.currentFrame?.frameID == 1)
        // The writes were committed: a later plain draw shows them.
        let target = try gpu.makeTarget(width: 32, height: 32)
        #expect(renderer.draw(targetPixelSize: (32, 32), displayScale: 1) { target } == .submitted(frameID: 1))
        let image = try await gpu.readBack(try #require(target.renderPassDescriptor.colorAttachments[0].texture))
        #expect(everyPixel(image, is: (250, 200, 10)))
        renderer.clearSource()
        #expect(await recorder.firstRelease() == BackgroundFrameRelease(
            frameID: 1, completedSubmissions: 1, failedSubmissions: 0,
            skippedSubmissions: 1, cancelledSubmissions: 0
        ))
    }

    @Test func `A zero-size target skips before anything is produced`() throws {
        let gpu = try GPUContext()
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        var produced = false
        let outcome = try renderer.drawProducing(targetPixelSize: (0, 20), displayScale: 1, produce: { _, _ in
            produced = true
            return nil
        }, acquireTarget: { nil })
        #expect(outcome == .skipped(.zeroSizeTarget))
        #expect(!produced)
    }

    @Test func `A produced frame encoded elsewhere is rejected and still released`() async throws {
        let gpu = try GPUContext()
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        let first = try gpu.makeTarget(width: 16, height: 16)
        _ = try renderer.drawProducing(targetPixelSize: (16, 16), displayScale: 1, produce: { commandBuffer, size in
            try? encodeClear(gpu, into: commandBuffer, width: size.width, height: size.height, color: (10, 20, 30), frameID: 1)
        }, acquireTarget: { first })

        // The producer encodes its writes into a command buffer nobody
        // commits, so nothing orders them before the renderer's sampling.
        let stray = try #require(gpu.queue.makeCommandBuffer())
        let recorder = ReleaseRecorder()
        #expect(throws: BackgroundSourceError.commandBufferNotEnqueued) {
            try renderer.drawProducing(targetPixelSize: (16, 16), displayScale: 1, produce: { _, size in
                try? encodeClear(gpu, into: stray, width: size.width, height: size.height, color: (1, 2, 3), frameID: 2, onRelease: recorder.handler)
            }, acquireTarget: { nil })
        }
        #expect(renderer.currentFrame?.frameID == 1)
        // Released once the draw's command buffer (committed on rejection)
        // has completed; it was never sampled.
        #expect(await recorder.firstRelease() == BackgroundFrameRelease(
            frameID: 2, completedSubmissions: 0, failedSubmissions: 0,
            skippedSubmissions: 0, cancelledSubmissions: 0
        ))
    }

    @Test func `Handing over a frame in an uncommitted command buffer is rejected until it is enqueued`() throws {
        let gpu = try GPUContext()
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        let commandBuffer = try #require(gpu.queue.makeCommandBuffer())
        let lease = try encodeClear(gpu, into: commandBuffer, width: 8, height: 8, color: (5, 6, 7), frameID: 1)
        #expect(throws: BackgroundSourceError.commandBufferNotEnqueued) {
            try renderer.setSource(lease)
        }
        commandBuffer.enqueue()
        try renderer.setSource(lease)
        #expect(renderer.currentFrame?.frameID == 1)
        commandBuffer.commit()
        lease.retire()
        renderer.clearSource()
    }

    @Test func `Writes encoded on another queue are rejected`() throws {
        let gpu = try GPUContext()
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        let otherQueue = try #require(gpu.device.makeCommandQueue())
        let commandBuffer = try #require(otherQueue.makeCommandBuffer())
        let lease = try encodeClear(gpu, into: commandBuffer, width: 8, height: 8, color: (5, 6, 7), frameID: 1)
        commandBuffer.commit()
        #expect(throws: BackgroundSourceError.queueMismatch) {
            try renderer.setSource(lease)
        }
        #expect(throws: BackgroundSourceError.queueMismatch) {
            try renderer.drawProducing(targetPixelSize: (8, 8), displayScale: 1, produce: { _, _ in lease }, acquireTarget: { nil })
        }
        lease.retire()
    }
}
