import Foundation
import GlassWeave
import Metal
import Testing

/// The laboratory's custom stage without a view: one `GlassRenderer`, the
/// surface's frame scheduler, the laboratory's procedural producer and
/// texture pool, and a ring of offscreen render targets standing in for a
/// layer's drawables. Each tick is one display-link step: advance content
/// time, request a frame, and draw it if the scheduler permits, exactly as
/// `GlassSurfaceView` does.
final class OffscreenStage {
    typealias Workload = CharacterizationTests.Workload

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let renderer: GlassRenderer
    let scheduler = FrameScheduler(isVisible: true)
    let pool: FrameTexturePool
    private let backgroundPipeline: any MTLRenderPipelineState
    private var targets: [any MTLTexture] = []
    private var nextTarget = 0
    private(set) var size = Workload.portrait
    private var ticks: UInt64 = 0
    private var nextFrameID: UInt64 = 1
    private let start = ContinuousClock.now

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "Characterization needs a Metal device")
        queue = try #require(device.makeCommandQueue())
        queue.label = "GlassWeave characterization"
        renderer = try GlassRenderer(commandQueue: queue)
        let library = try device.makeDefaultLibrary(bundle: .module)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Characterization procedural background"
        descriptor.vertexFunction = library.makeFunction(name: "lab_background_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "lab_background_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        backgroundPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        pool = FrameTexturePool(
            device: device,
            descriptor: FrameTexturePool.Descriptor(
                pixelFormat: .bgra8Unorm,
                usage: [.renderTarget, .shaderRead, .pixelFormatView],
                sampledPixelFormat: BackgroundColorConvention.sRGBOpaque.requiredPixelFormat
            ),
            capacity: Workload.poolCapacity
        )
        try makeTargets()
    }

    /// The class of the command queue, which names the Metal API Validation
    /// wrapper when that layer is active.
    var queueClassName: String {
        String(describing: type(of: queue))
    }

    // MARK: Ticks

    /// One display-link tick.
    func tick() {
        ticks += 1
        requestFrame()
    }

    /// Ticks at 60 Hz for `duration` and returns how many ticks ran. A late
    /// wake-up drops ticks instead of bunching them, like a display link.
    @discardableResult
    func tick(for duration: Duration) async throws -> Int {
        let clock = ContinuousClock()
        let begin = clock.now
        var deadline = begin
        var count = 0
        while clock.now - begin < duration {
            tick()
            count += 1
            deadline = max(deadline + Workload.tickInterval, clock.now)
            try await clock.sleep(until: deadline, tolerance: .microseconds(500))
        }
        return count
    }

    /// `count` ticks at 60 Hz.
    func tick(count: Int) async throws {
        for _ in 0..<count {
            tick()
            try await Task.sleep(for: Workload.tickInterval)
        }
    }

    /// Waits without blocking until no frame is in flight.
    func awaitIdle() async {
        let deadline = ContinuousClock.now + .seconds(10)
        while scheduler.statistics.framesInFlight > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(scheduler.statistics.framesInFlight == 0, "Frames still in flight after 10 s")
    }

    // MARK: Lifecycle

    func setVisible(_ visible: Bool) {
        if scheduler.setVisible(visible) {
            displayPass()
        }
    }

    /// A new target size, like a rotated or resized surface: new render
    /// targets, and a request for a frame at the new size. Targets still in
    /// use stay alive through their command buffers.
    func resize(to newSize: (width: Int, height: Int)) {
        guard newSize != size else { return }
        size = newSize
        try? makeTargets()
        requestFrame()
    }

    private func makeTargets() throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: GlassRenderer.outputPixelFormat, width: size.width, height: size.height, mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        targets = try (0..<Workload.renderTargets).map { index in
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            texture.label = "Characterization target \(index)"
            return texture
        }
        nextTarget = 0
    }

    // MARK: Drawing

    private func requestFrame() {
        if scheduler.request() {
            displayPass()
        }
    }

    /// One display pass, as `GlassSurfaceView.render(in:)` runs it. With the
    /// in-flight bound of two and three targets, a target is reused only
    /// after the frame that last rendered into it has completed.
    private func displayPass() {
        guard scheduler.beginDraw() == .draw else { return }
        let target = targets[nextTarget]
        nextTarget = (nextTarget + 1) % targets.count
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        var committed = false
        let scheduler = scheduler
        do {
            _ = try renderer.drawProducing(
                targetPixelSize: size, displayScale: Workload.displayScale,
                produce: { commandBuffer, pixelSize in produce(into: commandBuffer, pixelSize: pixelSize) },
                acquireTarget: { BackgroundDrawTarget(renderPassDescriptor: pass) },
                onCommit: { commandBuffer in
                    committed = true
                    scheduler.drawCommitted()
                    commandBuffer.addCompletedHandler { _ in _ = scheduler.frameCompleted() }
                }
            )
        } catch {
            Issue.record("The renderer rejected a produced frame: \(error)")
        }
        if !committed {
            scheduler.drawSkipped()
        }
    }

    /// The laboratory's producer: the procedural background at the current
    /// content time, frame-ID strip off, into a pooled texture.
    private func produce(into commandBuffer: any MTLCommandBuffer, pixelSize: (width: Int, height: Int)) -> BackgroundFrameLease? {
        guard let pooled = pool.checkout(width: pixelSize.width, height: pixelSize.height) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = pooled.storage
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            pool.returnUnused(pooled)
            return nil
        }
        let frameID = nextFrameID
        nextFrameID += 1
        var parameters: [Float] = [
            Float(Double(ticks) / Double(Workload.ticksPerSecond)),
            Float(Workload.displayScale),
            Float(frameID % (1 << 24)),
            0,
            0,
        ]
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setFragmentBytes(&parameters, length: parameters.count * MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let frame = BackgroundFrame(
            texture: pooled.texture, frameID: frameID, timestamp: ContinuousClock.now - start,
            colorConvention: .sRGBOpaque, readiness: .encoded(in: commandBuffer)
        )
        return pool.lease(frame, using: pooled) { _ in }
    }
}
