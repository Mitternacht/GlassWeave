#if canImport(UIKit)
import Metal
import MetalKit
import Testing
import UIKit
@testable import GlassWeave
@testable import GlassWeaveUIKit

/// The UIKit host of an explicit source: drawable size from local bounds and
/// display-scale traits, defined skips, and decorative input behavior.
@MainActor
struct GlassSurfaceViewTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        queue = try #require(device.makeCommandQueue())
    }

    private func makeSurface(scale: CGFloat, size: CGSize) throws -> GlassSurfaceView {
        let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
        surface.traitOverrides.displayScale = scale
        surface.frame = CGRect(origin: .zero, size: size)
        surface.updateTraitsIfNeeded()
        surface.layoutIfNeeded()
        return surface
    }

    /// An app-owned orientation pattern texture, uploaded on `queue` so the
    /// renderer's same-queue readiness contract holds.
    private func makeLease(
        frameID: UInt64 = 1,
        onRelease: @escaping @Sendable (BackgroundFrameRelease) -> Void = { _ in }
    ) throws -> BackgroundFrameLease {
        let pattern = OrientationPattern(width: 8, height: 6)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: pattern.width, height: pattern.height, mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let bytes = pattern.bgraBytes()
        let staging = try #require(device.makeBuffer(bytes: bytes, length: bytes.count, options: .storageModeShared))
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: staging, sourceOffset: 0,
            sourceBytesPerRow: pattern.width * 4, sourceBytesPerImage: bytes.count,
            sourceSize: MTLSize(width: pattern.width, height: pattern.height, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.commit()
        let frame = BackgroundFrame(
            texture: texture, frameID: frameID, timestamp: .zero,
            colorConvention: .sRGBOpaque, readiness: .committed(on: queue)
        )
        return BackgroundFrameLease(frame: frame, onRelease: onRelease)
    }

    @Test func `Pixel size is local bounds times the display scale`() throws {
        let surface = try makeSurface(scale: 3, size: CGSize(width: 100, height: 50))
        #expect(surface.pixelSize == (300, 150))
        #expect(surface.hostedMetalView.drawableSize == CGSize(width: 300, height: 150))
        #expect(surface.hostedMetalView.contentScaleFactor == 3)
    }

    @Test func `A display-scale trait change resizes the drawable`() throws {
        let surface = try makeSurface(scale: 3, size: CGSize(width: 100, height: 50))
        surface.traitOverrides.displayScale = 2
        surface.updateTraitsIfNeeded()
        surface.layoutIfNeeded()
        #expect(surface.pixelSize == (200, 100))
        #expect(surface.hostedMetalView.drawableSize == CGSize(width: 200, height: 100))
    }

    @Test func `Resizing and rotating the bounds resize the drawable`() throws {
        let surface = try makeSurface(scale: 2, size: CGSize(width: 393, height: 300))
        #expect(surface.pixelSize == (786, 600))
        // A rotation swaps the host's width and height.
        surface.frame.size = CGSize(width: 300, height: 393)
        surface.layoutIfNeeded()
        #expect(surface.pixelSize == (600, 786))
        // A safe-area or split-view change gives fractional point sizes.
        surface.frame.size = CGSize(width: 250.5, height: 120.25)
        surface.layoutIfNeeded()
        #expect(surface.pixelSize == (501, 241))
        #expect(surface.hostedMetalView.drawableSize == CGSize(width: 501, height: 241))
    }

    @Test func `Without a source the fallback shows and nothing is drawn`() throws {
        let surface = try makeSurface(scale: 2, size: CGSize(width: 40, height: 40))
        #expect(surface.hostedMetalView.isHidden)
        surface.renderNow()
        #expect(surface.lastRenderOutcome == .skipped(.missingSource))
    }

    @Test func `Zero-size bounds skip without requesting a drawable`() throws {
        let surface = try makeSurface(scale: 2, size: CGSize(width: 40, height: 30))
        let recorder = ReleaseRecorder()
        let lease = try makeLease(onRelease: recorder.handler)
        try surface.setSource(lease)
        lease.retire()

        surface.frame.size = CGSize(width: 0, height: 30)
        surface.layoutIfNeeded()
        #expect(surface.pixelSize == (0, 60))
        // The layer keeps its last valid size rather than an empty one.
        #expect(surface.hostedMetalView.drawableSize == CGSize(width: 80, height: 60))
        surface.renderNow()
        #expect(surface.lastRenderOutcome == .skipped(.zeroSizeTarget))

        // The zero-size skip never started a GPU use, so the producer hears
        // only that the presentation ended.
        surface.clearSource()
        #expect(recorder.releases == [BackgroundFrameRelease(
            frameID: 1, completedSubmissions: 0, failedSubmissions: 0,
            skippedSubmissions: 0, cancelledSubmissions: 0
        )])
    }

    @Test func `Setting and clearing a source shows and hides the Metal view`() throws {
        let surface = try makeSurface(scale: 2, size: CGSize(width: 40, height: 30))
        var outcomes: [BackgroundRenderOutcome] = []
        surface.renderObserver = { outcomes.append($0) }
        try surface.setSource(makeLease())
        #expect(!surface.hostedMetalView.isHidden)
        #expect(surface.renderer.currentFrame?.frameID == 1)
        surface.clearSource()
        #expect(surface.hostedMetalView.isHidden)
        #expect(surface.renderer.currentFrame == nil)
        #expect(outcomes.last == .skipped(.missingSource))
    }

    @Test func `A rejected source leaves the surface unchanged`() throws {
        let surface = try makeSurface(scale: 2, size: CGSize(width: 40, height: 30))
        try surface.setSource(makeLease(frameID: 5))
        #expect(throws: BackgroundSourceError.outOfOrderFrame(previousID: 5, receivedID: 3)) {
            try surface.setSource(makeLease(frameID: 3))
        }
        #expect(surface.renderer.currentFrame?.frameID == 5)
        #expect(!surface.hostedMetalView.isHidden)
    }

    @Test func `The panel stays in points and follows the normalization rule`() throws {
        let surface = try makeSurface(scale: 3, size: CGSize(width: 100, height: 60))
        let frame = CGRect(x: 10, y: 10, width: 80, height: 40)
        try surface.setPanel(GlassPanel(frame: frame, parameters: GlassParameters(cornerRadius: 50, bezelWidth: 12)))
        // Points, not pixels: the display scale applies only when drawing.
        #expect(surface.panel?.frame == frame)
        #expect(surface.panel?.parameters.cornerRadius == 20)
        var invalid = try #require(surface.panel)
        invalid.parameters.bezelWidth = .infinity
        #expect(throws: GlassParameterError.nonFinite(.bezelWidth)) {
            try surface.setPanel(invalid)
        }
        #expect(surface.panel?.parameters.bezelWidth == 12)
        try surface.setPanel(nil)
        #expect(surface.panel == nil)
    }

    @Test func `A frame producer runs inside each draw and a rejected frame is reported`() throws {
        let surface = try makeSurface(scale: 2, size: CGSize(width: 0, height: 30))
        var calls = 0
        surface.setFrameProducer { _, _ in
            calls += 1
            return nil
        }
        // Producing keeps the Metal view visible before the first frame.
        #expect(!surface.hostedMetalView.isHidden)
        surface.renderNow()
        #expect(calls == 0, "A zero-size target skips before producing")
        #expect(surface.lastRenderOutcome == .skipped(.zeroSizeTarget))

        surface.frame.size = CGSize(width: 40, height: 30)
        surface.layoutIfNeeded()
        let otherQueue = try #require(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 80, height: 60, mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        surface.setFrameProducer { _, size in
            calls += 1
            #expect(size == (80, 60))
            // Claims writes on another queue: nothing orders them.
            let frame = BackgroundFrame(
                texture: texture, frameID: 1, timestamp: .zero,
                colorConvention: .sRGBOpaque, readiness: .committed(on: otherQueue)
            )
            return BackgroundFrameLease(frame: frame) { _ in }
        }
        surface.renderNow()
        #expect(calls == 1)
        #expect(surface.lastProducedFrameError == .queueMismatch)
        #expect(surface.renderer.currentFrame == nil)

        surface.setFrameProducer(nil)
        #expect(surface.hostedMetalView.isHidden, "Without a producer or a source the fallback shows")
    }

    @Test func `The surface is decorative and passes touches through`() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let surface = try makeSurface(scale: 2, size: CGSize(width: 200, height: 200))
        container.addSubview(surface)
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 50, y: 50, width: 100, height: 44)
        container.addSubview(button)

        #expect(!surface.isAccessibilityElement)
        #expect(!surface.hostedMetalView.isAccessibilityElement)
        // Touches outside the button fall through the surface to its host;
        // touches on the button reach the button.
        #expect(container.hitTest(CGPoint(x: 10, y: 10), with: nil) === container)
        #expect(container.hitTest(CGPoint(x: 100, y: 70), with: nil) === button)
    }

    @Test func `A surface is a counted renderer`() throws {
        let (surface, created) = try RendererCensus.counting {
            try makeSurface(scale: 2, size: CGSize(width: 10, height: 10))
        }
        #expect(created == 1)
        #expect(surface.hostedMetalView.isPaused)
        #expect(surface.hostedMetalView.enableSetNeedsDisplay)
    }
}
#endif
