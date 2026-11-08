#if canImport(UIKit)
import Metal
import Testing
import UIKit
@testable import GlassWeave
@testable import GlassWeaveUIKit

/// The UIKit host's lifecycle: it draws only while visible in its own
/// window scene, two hosts keep independent visibility, and repeated
/// hide/show and resize cycles keep submissions and allocations bounded.
///
/// A test process has no window scenes, so these tests stand in for the
/// scene state with `sceneStateOverride`. The view's own and its ancestors'
/// hidden state are real. The laboratory's UI tests exercise real scenes.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct SurfaceLifecycleTests {
    /// Produces each frame into a pooled texture, like the laboratory.
    @MainActor
    final class PooledProducer {
        static let capacity = 3
        let pool: FrameTexturePool
        let releases = ReleaseRecorder()
        private(set) var produced = 0
        private var nextFrameID: UInt64 = 1

        init(device: any MTLDevice) {
            pool = FrameTexturePool(
                device: device,
                descriptor: FrameTexturePool.Descriptor(
                    pixelFormat: .bgra8Unorm,
                    usage: [.renderTarget, .shaderRead, .pixelFormatView],
                    sampledPixelFormat: .bgra8Unorm_srgb
                ),
                capacity: Self.capacity
            )
        }

        func produce(into commandBuffer: any MTLCommandBuffer, pixelSize: (width: Int, height: Int)) -> BackgroundFrameLease? {
            guard let pooled = pool.checkout(width: pixelSize.width, height: pixelSize.height) else { return nil }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = pooled.storage
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                pool.returnUnused(pooled)
                return nil
            }
            encoder.endEncoding()
            let frameID = nextFrameID
            nextFrameID += 1
            produced += 1
            let frame = BackgroundFrame(
                texture: pooled.texture, frameID: frameID, timestamp: .milliseconds(Int64(frameID)),
                colorConvention: .sRGBOpaque, readiness: .encoded(in: commandBuffer)
            )
            return pool.lease(frame, using: pooled, onRelease: releases.handler)
        }
    }

    let device: any MTLDevice
    let queue: any MTLCommandQueue

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        queue = try #require(device.makeCommandQueue())
    }

    private func makeSurface(in container: UIView, sceneState: SurfaceVisibility.SceneState?) throws -> (GlassSurfaceView, PooledProducer) {
        let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
        surface.sceneStateOverride = sceneState
        surface.traitOverrides.displayScale = 2
        surface.frame = container.bounds
        container.addSubview(surface)
        surface.updateTraitsIfNeeded()
        surface.layoutIfNeeded()
        let producer = PooledProducer(device: device)
        surface.setFrameProducer { [producer] commandBuffer, size in
            producer.produce(into: commandBuffer, pixelSize: size)
        }
        return (surface, producer)
    }

    /// Waits, without blocking the main actor, until no frame is in flight.
    private func awaitIdle(_ surfaces: GlassSurfaceView...) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while surfaces.contains(where: { $0.frameStatistics.framesInFlight > 0 }) {
            #expect(ContinuousClock.now < deadline, "GPU work did not complete")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test(arguments: [
        SurfaceVisibility.SceneState.foregroundActive, .foregroundInactive, .background, .unattached, .none,
    ])
    func `Only a shown surface in a foreground scene is visible`(sceneState: SurfaceVisibility.SceneState) {
        let foreground = sceneState == .foregroundActive || sceneState == .foregroundInactive
        for isInWindow in [true, false] {
            for hidden in [true, false] {
                let visibility = SurfaceVisibility(isInWindow: isInWindow, isHiddenInHierarchy: hidden, sceneState: sceneState)
                #expect(visibility.isVisible == (isInWindow && !hidden && foreground))
            }
        }
    }

    @Test func `A surface outside any window draws nothing`() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 30))
        let (surface, producer) = try makeSurface(in: container, sceneState: nil)
        surface.requestFrame()
        surface.renderNow()
        #expect(!surface.isVisible)
        #expect(surface.frameStatistics.submitted == 0)
        #expect(surface.frameStatistics.deferredWhileHidden >= 2)
        #expect(producer.produced == 0)
    }

    @Test func `Two surfaces follow their own scene and visibility`() async throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 30))
        let (first, firstProducer) = try makeSurface(in: container, sceneState: .foregroundActive)
        let (second, secondProducer) = try makeSurface(in: container, sceneState: .background)
        var secondChanges: [Bool] = []
        second.visibilityHandler = { secondChanges.append($0) }

        // The first scene is in the foreground, the second in the background.
        for surface in [first, second] {
            surface.requestFrame()
            surface.renderNow()
        }
        #expect(first.isVisible && !second.isVisible)
        #expect(first.frameStatistics.submitted == 1)
        #expect(second.frameStatistics.submitted == 0)
        #expect(second.frameStatistics.deferredWhileHidden >= 2)
        #expect(firstProducer.produced == 1 && secondProducer.produced == 0)

        // Swap: the second scene comes forward (inactive beside an active
        // one still counts as on screen), the first goes to the background.
        first.sceneStateOverride = .background
        second.sceneStateOverride = .foregroundInactive
        #expect(!first.isVisible && second.isVisible)
        #expect(secondChanges == [true])
        second.renderNow()
        first.requestFrame()
        first.renderNow()
        #expect(second.frameStatistics.submitted == 1, "The pending frame is drawn once")
        #expect(!second.scheduler.snapshot.hasPendingFrame)
        #expect(first.frameStatistics.submitted == 1, "The backgrounded surface submits nothing more")
        #expect(first.scheduler.snapshot.hasPendingFrame)
        try await awaitIdle(first, second)
    }

    @Test func `Hiding the surface or an ancestor defers drawing until shown`() async throws {
        let window = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 30))
        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        let (surface, _) = try makeSurface(in: container, sceneState: .foregroundActive)
        surface.renderNow()
        #expect(surface.frameStatistics.submitted == 1)

        for hide in [{ container.isHidden = true }, { surface.isHidden = true }, { surface.alpha = 0 }] {
            hide()
            surface.requestFrame()
            surface.renderNow()
            #expect(!surface.isVisible)
            #expect(surface.frameStatistics.submitted == 1)
            container.isHidden = false
            surface.isHidden = false
            surface.alpha = 1
            surface.requestFrame()
            #expect(surface.isVisible)
        }
        surface.renderNow()
        #expect(surface.frameStatistics.submitted == 2, "Three hidden periods leave one pending frame")
        try await awaitIdle(surface)
    }

    @Test func `100 hide and show and resize cycles stay within the bounds`() async throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 60, height: 40))
        let (surface, producer) = try makeSurface(in: container, sceneState: .foregroundActive)
        // Like the laboratory: give back free textures while hidden.
        surface.visibilityHandler = { visible in
            if !visible { producer.pool.trim() }
        }
        surface.renderNow()
        try await awaitIdle(surface)
        var peakLiveTextures = 0
        var liveWhileHidden: [Int] = []

        for cycle in 0..<100 {
            // Hide: the scene goes to the background; requests and display
            // passes submit nothing.
            surface.sceneStateOverride = .background
            let submittedBeforeHiding = surface.frameStatistics.submitted
            surface.requestFrame()
            surface.requestFrame()
            surface.renderNow()
            #expect(surface.frameStatistics.submitted == submittedBeforeHiding)
            try await awaitIdle(surface)
            liveWhileHidden.append(producer.pool.statistics.liveTextures)

            // Show and resize: the pending frame is drawn, then the new size.
            surface.sceneStateOverride = .foregroundActive
            surface.renderNow()
            surface.frame.size = cycle.isMultiple(of: 2) ? CGSize(width: 40, height: 60) : CGSize(width: 60, height: 40)
            surface.layoutIfNeeded()
            while surface.frameStatistics.framesInFlight == GlassSurfaceView.maximumFramesInFlight {
                try await Task.sleep(for: .milliseconds(1))
            }
            surface.renderNow()
            peakLiveTextures = max(peakLiveTextures, producer.pool.statistics.liveTextures)
        }
        try await awaitIdle(surface)
        surface.setFrameProducer(nil)
        surface.clearSource()
        let deadline = ContinuousClock.now + .seconds(10)
        while producer.releases.releases.count < producer.produced, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        producer.pool.trim()

        let statistics = surface.frameStatistics
        let pool = producer.pool.statistics
        let summary = """
        GlassSurfaceView lifecycle stress (iOS Simulator), 100 cycles of hide, two requests, show, resize
        requested \(statistics.requested), coalesced \(statistics.coalesced), submitted \(statistics.submitted), \
        completed \(statistics.completed), skipped \(statistics.skipped), \
        deferred while hidden \(statistics.deferredWhileHidden), deferred at limit \(statistics.deferredAtLimit), \
        peak in flight \(statistics.peakFramesInFlight)
        pool: allocations \(pool.allocations), checkouts \(pool.checkouts), discarded \(pool.discarded), \
        exhausted \(pool.exhaustedCheckouts), peak live \(peakLiveTextures), \
        live while hidden max \(liveWhileHidden.max() ?? -1), live after trim \(pool.liveTextures)
        frames produced \(producer.produced), released \(producer.releases.releases.count)
        """
        Attachment.record(summary, named: "surface-lifecycle-stress.txt")

        // One draw on settling plus two per cycle (show, resize); nothing
        // while hidden.
        #expect(statistics.submitted == 1 + 2 * 100)
        #expect(statistics.completed == statistics.submitted)
        #expect(statistics.peakFramesInFlight <= GlassSurfaceView.maximumFramesInFlight)
        #expect(statistics.deferredWhileHidden >= 300)
        // Hidden, only the presented frame's texture stays.
        #expect(liveWhileHidden.allSatisfy { $0 == 1 })
        #expect(peakLiveTextures <= PooledProducer.capacity)
        #expect(pool.exhaustedCheckouts == 0)
        #expect(producer.produced == statistics.submitted)
        #expect(producer.releases.releases.count == producer.produced)
        #expect(producer.releases.releases.allSatisfy { $0.completedSubmissions + $0.skippedSubmissions >= 1 && $0.failedSubmissions == 0 })
        #expect(pool.liveTextures == 0)
    }
}
#endif
