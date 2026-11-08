import CoreGraphics
import Foundation
import Metal
import Synchronization
import Testing
@testable import GlassWeave

/// Lifecycle on the GPU: the in-flight bound under a stalled GPU, resources
/// kept through teardown until the last GPU use completes, and 100 hide/show
/// and resize cycles with their submission and allocation counts.
///
/// An offscreen host drives the same scheduler, renderer, and texture pool
/// that `GlassSurfaceView` and the laboratory use, one display pass at a
/// time, so each count is exact.
@Suite(.timeLimit(.minutes(2)))
struct FrameLifecycleTests {
    /// GPU completions, recorded from Metal's completion threads and awaited
    /// by the test without blocking a thread.
    final class Completions: Sendable {
        private struct State {
            var count = 0
            var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        }

        private let state = Mutex(State())

        var count: Int {
            state.withLock { $0.count }
        }

        func record() {
            let ready = state.withLock { state in
                state.count += 1
                let count = state.count
                let ready = state.waiters.filter { $0.target <= count }
                state.waiters.removeAll { $0.target <= count }
                return ready
            }
            for waiter in ready { waiter.continuation.resume() }
        }

        /// Returns once at least `target` completions were recorded.
        func wait(forCount target: Int) async {
            await withCheckedContinuation { continuation in
                let done = state.withLock { state in
                    if state.count >= target { return true }
                    state.waiters.append((target, continuation))
                    return false
                }
                if done { continuation.resume() }
            }
        }
    }

    /// A host without a view: one renderer, one scheduler, and a pooled
    /// producer, drawing into offscreen targets.
    final class OffscreenHost {
        static let poolCapacity = 3

        let gpu: GPUContext
        let renderer: GlassRenderer
        let scheduler: FrameScheduler
        let pool: FrameTexturePool
        let completions = Completions()
        let releases = ReleaseRecorder()
        var size: (width: Int, height: Int)
        /// When set, each produced frame's command buffer waits for this
        /// event to reach 1 before running, which holds the frame in flight.
        var gate: (any MTLSharedEvent)?
        private(set) var produced = 0
        private(set) var lastStorage: (any MTLTexture)?
        private var nextFrameID: UInt64 = 1

        init(gpu: GPUContext, size: (width: Int, height: Int)) throws {
            self.gpu = gpu
            self.size = size
            renderer = try GlassRenderer(commandQueue: gpu.queue)
            try renderer.setPanel(GlassPanel(
                frame: CGRect(x: 4, y: 4, width: 24, height: 20),
                parameters: GlassParameters(cornerRadius: 6, bezelWidth: 6)
            ))
            scheduler = FrameScheduler(isVisible: true)
            pool = FrameTexturePool(
                device: gpu.device,
                descriptor: FrameTexturePool.Descriptor(
                    pixelFormat: .bgra8Unorm,
                    usage: [.renderTarget, .shaderRead, .pixelFormatView],
                    sampledPixelFormat: .bgra8Unorm_srgb
                ),
                capacity: Self.poolCapacity
            )
        }

        /// One display pass, as `GlassSurfaceView.render(in:)` runs it.
        @discardableResult
        func displayPass() throws -> FrameDrawDecision {
            let decision = scheduler.beginDraw()
            guard decision == .draw else { return decision }
            let target = try gpu.makeTarget(width: size.width, height: size.height)
            var committed = false
            let outcome = try renderer.drawProducing(
                targetPixelSize: size, displayScale: 1,
                produce: { commandBuffer, pixelSize in produce(into: commandBuffer, pixelSize: pixelSize) },
                acquireTarget: { target },
                onCommit: { [scheduler, completions] commandBuffer in
                    committed = true
                    scheduler.drawCommitted()
                    commandBuffer.addCompletedHandler { _ in
                        _ = scheduler.frameCompleted()
                        completions.record()
                    }
                }
            )
            if !committed { scheduler.drawSkipped() }
            #expect(outcome != .skipped(.encoderUnavailable))
            return decision
        }

        /// Runs display passes until no frame is pending, awaiting a GPU
        /// completion whenever the in-flight bound defers one, as the surface
        /// does when a completion schedules its pending frame.
        func runScheduledPasses() async throws {
            while scheduler.snapshot.hasPendingFrame, scheduler.snapshot.isVisible {
                if try displayPass() == .deferredAtLimit {
                    await completions.wait(forCount: completions.count + 1)
                }
            }
        }

        /// Awaits every submitted frame's completion.
        func awaitIdle() async {
            await completions.wait(forCount: scheduler.statistics.submitted)
        }

        private func produce(into commandBuffer: any MTLCommandBuffer, pixelSize: (width: Int, height: Int)) -> BackgroundFrameLease? {
            guard let pooled = pool.checkout(width: pixelSize.width, height: pixelSize.height) else { return nil }
            if let gate {
                commandBuffer.encodeWaitForEvent(gate, value: 1)
            }
            let frameID = nextFrameID
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = pooled.storage
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(frameID % 7) / 7, green: 0.5, blue: 0.25, alpha: 1)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                pool.returnUnused(pooled)
                return nil
            }
            encoder.endEncoding()
            nextFrameID += 1
            produced += 1
            lastStorage = pooled.storage
            let frame = BackgroundFrame(
                texture: pooled.texture, frameID: frameID, timestamp: .milliseconds(Int64(frameID)),
                colorConvention: .sRGBOpaque, readiness: .encoded(in: commandBuffer)
            )
            return pool.lease(frame, using: pooled, onRelease: releases.handler)
        }
    }

    @Test func `A stalled GPU holds the in-flight bound and nothing queues behind it`() async throws {
        let gpu = try GPUContext()
        let host = try OffscreenHost(gpu: gpu, size: (32, 32))
        let gate = try #require(gpu.device.makeSharedEvent())
        host.gate = gate

        // Ten requests, each followed by a display pass, while the GPU holds
        // every frame: only the bound is submitted, the rest wait as one
        // pending frame.
        for _ in 0..<10 {
            _ = host.scheduler.request()
            try host.displayPass()
        }
        var statistics = host.scheduler.statistics
        #expect(statistics.submitted == FrameScheduler.defaultMaxFramesInFlight)
        #expect(statistics.framesInFlight == FrameScheduler.defaultMaxFramesInFlight)
        #expect(statistics.deferredAtLimit == 10 - FrameScheduler.defaultMaxFramesInFlight)
        #expect(host.scheduler.snapshot.hasPendingFrame)
        #expect(host.produced == FrameScheduler.defaultMaxFramesInFlight, "Deferred passes produce nothing")
        #expect(host.pool.statistics.allocations == FrameScheduler.defaultMaxFramesInFlight)
        #expect(host.pool.statistics.exhaustedCheckouts == 0)
        #expect(host.releases.releases.isEmpty, "Nothing is released while the GPU holds it")

        // Release the GPU: both frames complete and the one pending frame
        // is drawn, once.
        host.gate = nil
        gate.signaledValue = 1
        await host.completions.wait(forCount: 2)
        try await host.runScheduledPasses()
        await host.awaitIdle()
        statistics = host.scheduler.statistics
        #expect(statistics.submitted == FrameScheduler.defaultMaxFramesInFlight + 1)
        #expect(statistics.completed == statistics.submitted)
        #expect(statistics.framesInFlight == 0)
        #expect(statistics.peakFramesInFlight == FrameScheduler.defaultMaxFramesInFlight)

        host.renderer.clearSource()
        while host.releases.releases.count < host.produced {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(host.releases.releases.allSatisfy { $0.completedSubmissions == 1 && $0.failedSubmissions == 0 })
        #expect(host.pool.statistics.texturesInUse == 0)
    }

    @Test func `Teardown keeps in-flight resources until their GPU work completes`() async throws {
        let gpu = try GPUContext()
        let gate = try #require(gpu.device.makeSharedEvent())
        var host: OffscreenHost? = try OffscreenHost(gpu: gpu, size: (32, 32))
        host?.gate = gate
        _ = host?.scheduler.request()
        try host?.displayPass()
        let releases = try #require(host?.releases)
        let completions = try #require(host?.completions)
        weak var storage = host?.lastStorage
        #expect(storage != nil)

        // Drop the renderer, scheduler, and pool while the frame is in flight.
        host = nil
        try await Task.sleep(for: .milliseconds(50))
        #expect(releases.releases.isEmpty, "The frame's GPU work has not run")
        #expect(storage != nil, "The command buffer still holds the texture it writes and samples")
        #expect(completions.count == 0)

        gate.signaledValue = 1
        let release = await releases.firstRelease()
        #expect(release == BackgroundFrameRelease(
            frameID: 1, completedSubmissions: 1, failedSubmissions: 0,
            skippedSubmissions: 0, cancelledSubmissions: 0
        ))
        // With the GPU done and every owner gone, the texture is freed.
        let deadline = ContinuousClock.now + .seconds(2)
        while storage != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(storage == nil)
    }

    @Test func `100 hide and show cycles and 100 resizes keep submissions and allocations bounded`() async throws {
        let gpu = try GPUContext()
        let (host, renderersCreated) = try RendererCensus.counting {
            try OffscreenHost(gpu: gpu, size: (64, 48))
        }
        #expect(renderersCreated == 1)
        var peakLiveTextures = 0
        func notePool() {
            peakLiveTextures = max(peakLiveTextures, host.pool.statistics.liveTextures)
        }

        // Settle once.
        _ = host.scheduler.request()
        try await host.runScheduledPasses()
        await host.awaitIdle()
        let settled = host.scheduler.statistics
        let settledPool = host.pool.statistics

        // Phase A: hide, request three times, let a display pass arrive,
        // show again. Same size throughout.
        for _ in 0..<100 {
            #expect(!host.scheduler.setVisible(false))
            let submittedBeforeHiding = host.scheduler.statistics.submitted
            for _ in 0..<3 { #expect(!host.scheduler.request()) }
            #expect(try host.displayPass() == .deferredWhileHidden)
            #expect(host.scheduler.statistics.submitted == submittedBeforeHiding, "No submission while hidden")
            // Showing draws the pending frame now, or after a completion if
            // the bound is reached.
            let drawsNow = host.scheduler.setVisible(true)
            #expect(drawsNow || host.scheduler.statistics.framesInFlight == FrameScheduler.defaultMaxFramesInFlight)
            try await host.runScheduledPasses()
            notePool()
        }
        await host.awaitIdle()
        let afterHideShow = host.scheduler.statistics
        let hideShowPool = host.pool.statistics

        // Phase B: resize every cycle, alternating portrait and landscape.
        for cycle in 0..<100 {
            host.size = cycle.isMultiple(of: 2) ? (48, 64) : (64, 48)
            _ = host.scheduler.request()
            try await host.runScheduledPasses()
            notePool()
        }
        await host.awaitIdle()
        let afterResize = host.scheduler.statistics
        let resizePool = host.pool.statistics

        // Teardown of the source and the pool's free textures.
        host.renderer.clearSource()
        while host.releases.releases.count < host.produced {
            try await Task.sleep(for: .milliseconds(5))
        }
        host.pool.trim()
        let finalPool = host.pool.statistics

        let summary = """
        GlassWeave frame lifecycle stress, pool capacity \(OffscreenHost.poolCapacity), \
        in-flight bound \(FrameScheduler.defaultMaxFramesInFlight)
        settle: submitted \(settled.submitted), allocations \(settledPool.allocations)
        100 hide/show: submitted \(afterHideShow.submitted - settled.submitted), \
        requested \(afterHideShow.requested - settled.requested), \
        deferred while hidden \(afterHideShow.deferredWhileHidden), \
        coalesced \(afterHideShow.coalesced), \
        allocations \(hideShowPool.allocations - settledPool.allocations)
        100 resizes: submitted \(afterResize.submitted - afterHideShow.submitted), \
        allocations \(resizePool.allocations - hideShowPool.allocations), \
        discarded \(resizePool.discarded - hideShowPool.discarded)
        peak frames in flight \(afterResize.peakFramesInFlight), peak live textures \(peakLiveTextures), \
        deferred at limit \(afterResize.deferredAtLimit)
        frames produced \(host.produced), released \(host.releases.releases.count), \
        GPU completions \(host.completions.count)
        after trim: live textures \(finalPool.liveTextures), in use \(finalPool.texturesInUse), bytes \(finalPool.liveBytes)
        """
        Attachment.record(summary, named: "frame-lifecycle-stress.txt")

        // Hide/show: one submission per show, none while hidden, and the
        // pooled textures are recycled rather than reallocated.
        #expect(afterHideShow.submitted - settled.submitted == 100)
        #expect(afterHideShow.deferredWhileHidden == 400)
        #expect(afterHideShow.coalesced == 200)
        #expect(hideShowPool.allocations <= OffscreenHost.poolCapacity)
        // Resize: one submission per size change; each new size needs one
        // new texture, and old-size textures are discarded, never kept.
        #expect(afterResize.submitted - afterHideShow.submitted == 100)
        #expect(resizePool.allocations - hideShowPool.allocations == 100)
        // Fixed bounds throughout.
        #expect(afterResize.peakFramesInFlight <= FrameScheduler.defaultMaxFramesInFlight)
        #expect(peakLiveTextures <= OffscreenHost.poolCapacity)
        #expect(afterResize.completed == afterResize.submitted)
        // Every frame released exactly once, after its GPU work completed.
        let frameIDs = host.releases.releases.map(\.frameID)
        #expect(Set(frameIDs).count == frameIDs.count)
        #expect(host.produced == afterResize.submitted)
        #expect(host.releases.releases.allSatisfy { $0.completedSubmissions == 1 && $0.failedSubmissions == 0 })
        #expect(finalPool.liveTextures == 0 && finalPool.texturesInUse == 0)
    }
}
