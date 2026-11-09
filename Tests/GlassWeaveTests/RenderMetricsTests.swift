import CoreGraphics
import Metal
import Testing
@testable import GlassWeave

/// `RenderMetrics`: percentile definitions, the bounded sample window, and
/// what a measured renderer records for drawn, skipped, declined, and
/// rejected frames.
@Suite(.timeLimit(.minutes(1)))
struct RenderMetricsTests {
    // MARK: Distributions

    @Test func `Percentiles of 1 through 100 are exact ranks`() throws {
        let values = (1...100).map { Duration.milliseconds($0) }.shuffled()
        let distribution = try #require(RenderMetrics.Distribution(values))
        #expect(distribution.count == 100)
        // Nearest rank: the 50th, 95th, and 99th of 100 sorted values.
        #expect(distribution.p50 == .milliseconds(50))
        #expect(distribution.p95 == .milliseconds(95))
        #expect(distribution.p99 == .milliseconds(99))
        #expect(distribution.maximum == .milliseconds(100))
    }

    @Test func `Nearest-rank percentiles match the definition for every count`() throws {
        var generator = SplitMix64(seed: 0x6757_0009)
        for count in 1...240 {
            let values = (0..<count).map { _ in Duration.microseconds(Int64(generator.next() % 5_000)) }
            let distribution = try #require(RenderMetrics.Distribution(values))
            for (percent, reported) in [(50, distribution.p50), (95, distribution.p95), (99, distribution.p99)] {
                // The smallest observed value with at least percent % of the
                // values at or below it.
                let expected = values.sorted().first { candidate in
                    values.filter { $0 <= candidate }.count * 100 >= percent * count
                }
                #expect(reported == expected, "p\(percent) of \(count) values")
            }
            #expect(distribution.maximum == values.max())
        }
        #expect(RenderMetrics.Distribution([]) == nil)
    }

    // MARK: Window

    private func sample(_ frameID: UInt64, completed: Bool = true, gpu: Double? = 0.001) -> RenderMetrics.Sample {
        RenderMetrics.Sample(
            frameID: frameID, drewFrame: true,
            encodeDuration: .microseconds(Int64(frameID)), produceDuration: .zero, targetAcquisitionDuration: .zero,
            gpuStartTime: gpu.map { _ in 10 }, gpuEndTime: gpu.map { 10 + $0 },
            completed: completed, deviceAllocatedBytes: Int(frameID) * 1_000
        )
    }

    @Test func `The window keeps the most recent samples and counts every one`() {
        let metrics = RenderMetrics(capacity: 5)
        for frameID in 1...12 {
            metrics.record(sample(UInt64(frameID), completed: frameID != 3))
        }
        #expect(metrics.samples.map(\.frameID) == [8, 9, 10, 11, 12])
        #expect(metrics.counts.commandBuffersCompleted == 11)
        #expect(metrics.counts.commandBuffersFailed == 1)
        let summary = metrics.summary()
        #expect(summary.encode?.count == 5)
        #expect(summary.encode?.p50 == .microseconds(10))
        #expect(summary.peakDeviceAllocatedBytes == 12_000)
        #expect(summary.latestDeviceAllocatedBytes == 12_000)
    }

    @Test func `Summaries use drawn and completed frames and count missing GPU times`() {
        let metrics = RenderMetrics()
        metrics.record(sample(1))
        metrics.record(sample(2, gpu: nil))
        metrics.record(sample(3, completed: false))
        metrics.record(RenderMetrics.Sample(
            frameID: 4, drewFrame: false, encodeDuration: .seconds(1), produceDuration: .zero,
            targetAcquisitionDuration: .zero, gpuStartTime: 1, gpuEndTime: 2, completed: true,
            deviceAllocatedBytes: nil
        ))
        let summary = metrics.summary()
        #expect(summary.encode?.count == 2, "Only frames 1 and 2 drew and completed")
        #expect(summary.encode?.maximum == .microseconds(2))
        #expect(summary.gpu?.count == 1)
        #expect(summary.samplesWithoutGPUTime == 1)
    }

    // MARK: A measured renderer

    /// Encodes a clear of a pooled texture into `commandBuffer`, as the
    /// laboratory's producer does, and returns the frame's lease.
    private static func produce(
        pool: FrameTexturePool, into commandBuffer: any MTLCommandBuffer,
        size: (width: Int, height: Int), frameID: UInt64
    ) -> BackgroundFrameLease? {
        guard let pooled = pool.checkout(width: size.width, height: size.height) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = pooled.storage
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            pool.returnUnused(pooled)
            return nil
        }
        encoder.endEncoding()
        let frame = BackgroundFrame(
            texture: pooled.texture, frameID: frameID, timestamp: .milliseconds(Int64(frameID)),
            colorConvention: .sRGBOpaque, readiness: .encoded(in: commandBuffer)
        )
        return pool.lease(frame, using: pooled) { _ in }
    }

    private static func makePool(_ gpu: GPUContext) -> FrameTexturePool {
        FrameTexturePool(
            device: gpu.device,
            descriptor: FrameTexturePool.Descriptor(
                pixelFormat: .bgra8Unorm, usage: [.renderTarget, .shaderRead, .pixelFormatView],
                sampledPixelFormat: .bgra8Unorm_srgb
            ),
            capacity: 3
        )
    }

    /// Waits without blocking until `metrics` has `count` finished command
    /// buffers.
    private static func awaitFinished(_ metrics: RenderMetrics, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while metrics.counts.commandBuffersCompleted + metrics.counts.commandBuffersFailed < count {
            try #require(ContinuousClock.now < deadline, "Command buffers did not finish")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func `A measured renderer records each drawn frame's CPU and GPU cost`() async throws {
        let gpu = try GPUContext()
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        try renderer.setPanel(GlassPanel(
            frame: CGRect(x: 8, y: 8, width: 48, height: 32),
            parameters: GlassParameters(cornerRadius: 8, bezelWidth: 8, refraction: 1)
        ))
        let metrics = RenderMetrics()
        renderer.metrics = metrics
        let pool = Self.makePool(gpu)
        for frameID in UInt64(1)...5 {
            let target = try gpu.makeTarget(width: 64, height: 48)
            let outcome = try renderer.drawProducing(
                targetPixelSize: (64, 48), displayScale: 1,
                produce: { commandBuffer, size in Self.produce(pool: pool, into: commandBuffer, size: size, frameID: frameID) },
                acquireTarget: { target }
            )
            #expect(outcome == .submitted(frameID: frameID))
            try await Self.awaitFinished(metrics, count: Int(frameID))
        }
        let samples = metrics.samples
        #expect(samples.map(\.frameID) == [1, 2, 3, 4, 5])
        for sample in samples {
            #expect(sample.drewFrame && sample.completed)
            #expect(sample.encodeDuration > .zero)
            #expect(sample.produceDuration > .zero)
            #expect(sample.targetAcquisitionDuration >= .zero)
            // GPU timestamps come together or not at all, in order.
            #expect((sample.gpuStartTime == nil) == (sample.gpuEndTime == nil))
            if let start = sample.gpuStartTime, let end = sample.gpuEndTime {
                #expect(end >= start && start > 0)
            }
            #if targetEnvironment(simulator)
            // The iOS Simulator reports no allocation sizes.
            #expect(sample.deviceAllocatedBytes == nil)
            #else
            // A Mac or device GPU reports when it ran each command buffer
            // and what the process has allocated on it.
            #expect(try #require(sample.gpuDuration) > .zero)
            #expect(try #require(sample.deviceAllocatedBytes) > 0)
            #endif
        }
        let counts = metrics.counts
        #expect(counts.draws == 5 && counts.drawn == 5 && counts.skipped == 0)
        #expect(counts.commandBuffersCommitted == 5 && counts.commandBuffersCompleted == 5)
        let summary = metrics.summary()
        let encode = try #require(summary.encode)
        #expect(encode.count == 5)
        #expect(encode.p50 <= encode.p95 && encode.p95 <= encode.p99 && encode.p99 <= encode.maximum)
        renderer.clearSource()
    }

    @Test func `Skips, declined productions, and rejected frames are counted`() async throws {
        let gpu = try GPUContext()
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        let metrics = RenderMetrics()
        renderer.metrics = metrics
        let pool = Self.makePool(gpu)

        // No source: a skip that commits nothing.
        #expect(renderer.draw(targetPixelSize: (32, 32), displayScale: 1, acquireTarget: { nil }) == .skipped(.missingSource))
        // Frame 1 is drawn.
        let target = try gpu.makeTarget(width: 32, height: 32)
        _ = try renderer.drawProducing(targetPixelSize: (32, 32), displayScale: 1, produce: { commandBuffer, size in
            Self.produce(pool: pool, into: commandBuffer, size: size, frameID: 1)
        }, acquireTarget: { target })
        // The producer declines: frame 1 is drawn again.
        #expect(try renderer.drawProducing(targetPixelSize: (32, 32), displayScale: 1, produce: { _, _ in nil }, acquireTarget: { target }) == .submitted(frameID: 1))
        // Frame 2 is produced but no drawable is available: its writes are
        // committed in a command buffer that draws nothing.
        #expect(try renderer.drawProducing(targetPixelSize: (32, 32), displayScale: 1, produce: { commandBuffer, size in
            Self.produce(pool: pool, into: commandBuffer, size: size, frameID: 2)
        }, acquireTarget: { nil }) == .skipped(.drawableUnavailable))
        // Zero size: skipped before anything is produced.
        #expect(try renderer.drawProducing(targetPixelSize: (0, 32), displayScale: 1, produce: { _, _ in
            Issue.record("A zero-size draw produced a frame")
            return nil
        }, acquireTarget: { target }) == .skipped(.zeroSizeTarget))
        // Frame 3 breaks the contract (a non-sRGB texture declared sRGB):
        // rejected, and its writes are still committed.
        let wrongFormat = try gpu.makeTexture(width: 32, height: 32, pixelFormat: .bgra8Unorm, usage: [.renderTarget, .shaderRead])
        #expect(throws: BackgroundSourceError.pixelFormatMismatch(declared: .sRGBOpaque, actual: .bgra8Unorm)) {
            try renderer.drawProducing(targetPixelSize: (32, 32), displayScale: 1, produce: { commandBuffer, _ in
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = wrongFormat
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
                let frame = BackgroundFrame(
                    texture: wrongFormat, frameID: 3, timestamp: .seconds(1),
                    colorConvention: .sRGBOpaque, readiness: .encoded(in: commandBuffer)
                )
                return BackgroundFrameLease(frame: frame) { _ in }
            }, acquireTarget: { target })
        }

        try await Self.awaitFinished(metrics, count: 4)
        let counts = metrics.counts
        #expect(counts.draws == 6)
        #expect(counts.drawn == 2)
        #expect(counts.skipped == 3)
        #expect(counts.rejected == 1)
        #expect(counts.declinedProductions == 1)
        #expect(counts.commandBuffersCommitted == 4)
        #expect(counts.commandBuffersCompleted == 4)
        let samples = metrics.samples.sorted { $0.frameID < $1.frameID }
        #expect(samples.map(\.frameID) == [1, 1, 2, 3])
        #expect(samples.map(\.drewFrame) == [true, true, false, false])
        // Only the two drawn frames enter the distributions.
        #expect(metrics.summary().encode?.count == 2)
        renderer.clearSource()
    }

    @Test func `Reset ignores command buffers committed before it`() async throws {
        let gpu = try GPUContext()
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        let metrics = RenderMetrics()
        renderer.metrics = metrics
        let pool = Self.makePool(gpu)
        let gate = try #require(gpu.device.makeSharedEvent())
        let target = try gpu.makeTarget(width: 32, height: 32)
        _ = try renderer.drawProducing(targetPixelSize: (32, 32), displayScale: 1, produce: { commandBuffer, size in
            // Hold the frame on the GPU until the test signals.
            commandBuffer.encodeWaitForEvent(gate, value: 1)
            return Self.produce(pool: pool, into: commandBuffer, size: size, frameID: 1)
        }, acquireTarget: { target })
        #expect(metrics.counts.commandBuffersCommitted == 1)
        metrics.reset()
        #expect(metrics.counts == RenderMetrics.Counts())
        gate.signaledValue = 1

        // A later frame is recorded; the earlier one, completing after the
        // reset, is not.
        _ = try renderer.drawProducing(targetPixelSize: (32, 32), displayScale: 1, produce: { commandBuffer, size in
            Self.produce(pool: pool, into: commandBuffer, size: size, frameID: 2)
        }, acquireTarget: { target })
        try await Self.awaitFinished(metrics, count: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(metrics.samples.map(\.frameID) == [2])
        #expect(metrics.counts.commandBuffersCommitted == 1)
        #expect(metrics.counts.commandBuffersCompleted == 1)
        renderer.clearSource()
    }
}
