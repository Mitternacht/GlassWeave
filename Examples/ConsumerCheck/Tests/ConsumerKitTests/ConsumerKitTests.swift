import CoreGraphics
import Foundation
import GlassWeave
import Metal
import Testing
import ConsumerKit
#if canImport(UIKit)
import GlassWeaveUIKit
import MetalKit
import UIKit
#endif

/// The GlassWeave candidate seen from outside the package: public API only.
struct ConsumerKitTests {
    @Test func `Custom mode renders the panel over the consumer's own background`() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        // scripts/consumer_check.sh runs this with Metal API Validation.
        if ProcessInfo.processInfo.environment["MTL_DEBUG_LAYER"] == "1" {
            #expect(String(describing: type(of: queue)).contains("Debug"), "Validation layer not active: \(type(of: queue))")
        }
        // A fully tinted, non-refracting panel: its interior shows the tint.
        let panel = GlassPanel(
            frame: CGRect(x: 16, y: 16, width: 32, height: 32),
            parameters: GlassParameters(cornerRadius: 8, bezelWidth: 4, refraction: 0, edgeHighlight: 0,
                                        tint: GlassTint(red: 1, green: 0, blue: 0, strength: 1))
        )
        let glass = try OffscreenGlass(commandQueue: queue, panel: panel)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: GlassRenderer.outputPixelFormat, width: 64, height: 64, mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        let target = try #require(device.makeTexture(descriptor: descriptor))

        let outcome = try glass.draw(background: MTLClearColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1), into: target)
        #expect(outcome == .submitted(frameID: 1))
        let pixels = try await readBack(target, queue: queue)
        // BGRA bytes: outside the panel the background, inside the tint.
        #expect(isClose(pixels.at(x: 4, y: 4), to: (204, 128, 51, 255)))
        #expect(isClose(pixels.at(x: 32, y: 32), to: (0, 0, 255, 255)))
        #expect(glass.metrics.counts.drawn == 1)
    }

    #if canImport(UIKit)
    @MainActor
    @Test func `Native mode is Apple glass around a working button`() throws {
        var taps = 0
        let glass = makeNativeControl(title: "Native", action: UIAction { _ in taps += 1 })
        #expect(glass.effect is UIGlassEffect)
        let button = try #require(glass.contentView.subviews.first as? UIButton)
        button.sendActions(for: .primaryActionTriggered)
        #expect(taps == 1)
        #expect(!glass.subviews.contains { $0 is MTKView })
    }

    @MainActor
    @Test func `The UIKit surface accepts a producer and a panel and defers while not in a window`() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
        surface.frame = CGRect(x: 0, y: 0, width: 120, height: 90)
        surface.layoutIfNeeded()
        var produced = 0
        surface.setFrameProducer { _, _ in
            produced += 1
            return nil
        }
        try surface.setPanel(GlassPanel(frame: CGRect(x: 10, y: 10, width: 100, height: 60)))
        surface.requestFrame()
        #expect(!surface.isVisible)
        #expect(surface.frameStatistics.deferredWhileHidden >= 1)
        #expect(surface.frameStatistics.submitted == 0)
        #expect(produced == 0)
        #expect(surface.panel?.frame == CGRect(x: 10, y: 10, width: 100, height: 60))
        #expect(surface.isAccessibilityElement == false && surface.accessibilityElementsHidden)
    }
    #endif

    private struct Pixels {
        let width: Int
        let bytes: [UInt8]
        func at(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let i = (y * width + x) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }
    }

    private func isClose(_ a: (UInt8, UInt8, UInt8, UInt8), to b: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        abs(Int(a.0) - Int(b.0)) <= 1 && abs(Int(a.1) - Int(b.1)) <= 1
            && abs(Int(a.2) - Int(b.2)) <= 1 && abs(Int(a.3) - Int(b.3)) <= 1
    }

    private func readBack(_ texture: any MTLTexture, queue: any MTLCommandQueue) async throws -> Pixels {
        let length = texture.width * texture.height * 4
        let buffer = try #require(queue.device.makeBuffer(length: length, options: .storageModeShared))
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: texture.width * 4,
            destinationBytesPerImage: length
        )
        blit.endEncoding()
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { _ in continuation.resume() }
            commandBuffer.commit()
        }
        return Pixels(width: texture.width, bytes: Array(UnsafeRawBufferPointer(start: buffer.contents(), count: length)))
    }
}
