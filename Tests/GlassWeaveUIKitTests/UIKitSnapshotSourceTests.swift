#if canImport(UIKit)
import Metal
import Testing
import UIKit
@testable import GlassWeave
@testable import GlassWeaveUIKit

/// The UIKit snapshot source (GW-31): a snapshot of a known pattern view matches
/// the view's pixels within one 8-bit step, in the right orientation and scale.
/// The one safety test of the task. It also checks, in the same run, that the
/// frame is a valid source for the renderer, that repeated refreshes reuse
/// pooled textures without recreating the renderer, and the normalization rule.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct UIKitSnapshotSourceTests {
    /// The pattern, in points: 48 x 32 (not square, so a transposed or flipped
    /// capture cannot match). Four quadrants, a white block near the top-left
    /// corner and a black bar near the bottom-right corner, all on whole points
    /// so no pixel is anti-aliased.
    private static let size = CGSize(width: 48, height: 32)

    private static func expected(x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
        if (2..<8).contains(x), (2..<6).contains(y) { return (255, 255, 255) }
        if (36..<46).contains(x), (28..<30).contains(y) { return (0, 0, 0) }
        switch (x < 24, y < 16) {
        case (true, true): return (255, 0, 0)
        case (false, true): return (0, 255, 0)
        case (true, false): return (0, 0, 255)
        case (false, false): return (255, 255, 0)
        }
    }

    private func makePatternView() -> UIView {
        let root = UIView(frame: CGRect(origin: .zero, size: Self.size))
        func block(_ rect: CGRect, _ r: Double, _ g: Double, _ b: Double) {
            let view = UIView(frame: rect)
            view.backgroundColor = UIColor(red: r, green: g, blue: b, alpha: 1)
            root.addSubview(view)
        }
        block(CGRect(x: 0, y: 0, width: 24, height: 16), 1, 0, 0)
        block(CGRect(x: 24, y: 0, width: 24, height: 16), 0, 1, 0)
        block(CGRect(x: 0, y: 16, width: 24, height: 16), 0, 0, 1)
        block(CGRect(x: 24, y: 16, width: 24, height: 16), 1, 1, 0)
        block(CGRect(x: 2, y: 2, width: 6, height: 4), 1, 1, 1)
        block(CGRect(x: 36, y: 28, width: 10, height: 2), 0, 0, 0)
        return root
    }

    /// Reads a 4-byte-per-pixel texture back (BGRA). It waits for the tiny blit
    /// and does not suspend: a suspended main-actor test lets other main-actor
    /// suites run in the middle of this one, and the existing corner-radii test
    /// of the enhanced native glass does not survive that.
    private func readBack(_ texture: any MTLTexture, queue: any MTLCommandQueue) throws -> [UInt8] {
        let bytesPerRow = texture.width * 4
        let length = bytesPerRow * texture.height
        let buffer = try #require(queue.device.makeBuffer(length: length, options: .storageModeShared))
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: length
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        return Array(UnsafeRawBufferPointer(start: buffer.contents(), count: length))
    }

    /// Compares every pixel of a read-back snapshot of `region` (in points) with
    /// the pattern's own pixels within one 8-bit step; returns the worst step.
    private func worstDifference(_ bytes: [UInt8], width: Int, height: Int, region: CGRect) -> Int {
        var worst = 0
        for py in 0..<height {
            for px in 0..<width {
                let x = Double(region.minX) + (Double(px) + 0.5) / Double(width) * Double(region.width)
                let y = Double(region.minY) + (Double(py) + 0.5) / Double(height) * Double(region.height)
                let want = Self.expected(x: x, y: y)
                let offset = (py * width + px) * 4
                // BGRA, sRGB-encoded, opaque.
                worst = max(
                    worst, abs(Int(bytes[offset + 2]) - want.r), abs(Int(bytes[offset + 1]) - want.g),
                    abs(Int(bytes[offset]) - want.b), 255 - Int(bytes[offset + 3])
                )
            }
        }
        return worst
    }

    @Test func `A snapshot of a known pattern view matches its pixels in orientation and scale, and refreshes reuse textures`() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        let queue = try #require(device.makeCommandQueue())
        let renderer = try GlassRenderer(commandQueue: queue)
        let source = try UIKitSnapshotSource(renderer: renderer)
        let pattern = makePatternView()

        // The whole view at three scales: size, orientation and color.
        for scale in [1, 2, 3] as [CGFloat] {
            let (lease, report) = try source.capture(pattern, scale: scale)
            let texture = lease.frame.texture
            #expect(texture.width == Int(48 * scale) && texture.height == Int(32 * scale), "The pixel size is the view's size times the scale")
            #expect(texture.pixelFormat == .bgra8Unorm_srgb && lease.frame.colorConvention == .sRGBOpaque)
            #expect(lease.frame.orientation == .up)
            #expect(report.technique == .layerRender, "A view outside a window is rendered from its layers")
            #expect(!report.wasScaledDown)
            let bytes = try readBack(texture, queue: queue)
            let worst = worstDifference(bytes, width: texture.width, height: texture.height, region: CGRect(origin: .zero, size: Self.size))
            #expect(worst <= 1, "Scale \(scale): every pixel within one 8-bit step, worst \(worst)")
            // The renderer accepts the frame: device, format, usage and queue.
            try renderer.setSource(lease)
            lease.retire()
        }

        // A region: the bottom-right quadrant plus the black bar, at scale 2.
        let region = CGRect(x: 24, y: 16, width: 24, height: 16)
        let (lease, report) = try source.capture(pattern, region: region, scale: 2)
        #expect(report.pixelWidth == 48 && report.pixelHeight == 32)
        let bytes = try readBack(lease.frame.texture, queue: queue)
        #expect(worstDifference(bytes, width: 48, height: 32, region: region) <= 1, "A region starts at its own top-left corner")
        lease.retire()

        // Frame identity increases, and the renderer's own frame carries on from it.
        #expect(report.frameID == 4, "Four captures so far: IDs 1, 2, 3, 4")

        // Refreshes through a surface reuse pooled textures and never recreate the renderer.
        let surface = GlassSurfaceView(renderer: renderer)
        surface.traitOverrides.displayScale = 2
        surface.frame = CGRect(origin: .zero, size: Self.size)
        surface.updateTraitsIfNeeded()
        let allocationsBefore = source.poolStatistics.allocations
        for _ in 0..<6 {
            try source.refresh(surface, from: pattern, region: pattern.bounds)
        }
        #expect(surface.renderer === renderer)
        let pool = source.poolStatistics
        #expect(pool.allocations - allocationsBefore <= 2, "Six refreshes allocate at most the presented texture and the next one: \(pool)")
        #expect(pool.liveTextures <= pool.capacity, "Textures come from the bounded pool: \(pool)")
        #expect(pool.texturesInUse == 1, "Only the presented frame holds a texture: \(pool)")
        #expect(renderer.currentFrame?.frameID == source.lastReport?.frameID)

        // Normalization: a non-finite number is rejected naming the field; an empty region is refused.
        #expect(throws: UIKitSnapshotError.nonFinite(.scale)) { try source.capture(pattern, scale: .nan) }
        #expect(throws: UIKitSnapshotError.nonFinite(.regionWidth)) {
            try source.capture(pattern, region: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 4))
        }
        #expect(throws: UIKitSnapshotError.emptyRegion) { try source.capture(pattern, region: CGRect(x: 4, y: 4, width: 0, height: 8)) }
    }
}
#endif
