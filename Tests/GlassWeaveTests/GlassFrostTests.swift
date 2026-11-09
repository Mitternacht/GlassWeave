import Metal
import Testing
@_spi(FrostLab) @testable import GlassWeave

/// The one safety test of the frost pyramid infrastructure (GW-24a): the
/// off-by-default rule, and a source that stays what it was through every
/// level. Everything else about the pyramid is shown in the laboratory.
@Suite(.timeLimit(.minutes(1)))
struct GlassFrostTests {
    /// sRGB-encoded 8-bit value to linear light.
    private func linear(_ value: UInt8) -> Float {
        let c = Float(value) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    @Test func `Frost none builds nothing and a uniform source stays uniform through the pyramid`() async throws {
        let gpu = try GPUContext()
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        let metrics = RenderMetrics()
        renderer.metrics = metrics
        let (width, height) = (160, 96)
        let (red, green, blue): (UInt8, UInt8, UInt8) = (80, 140, 220)
        var bgra: [UInt8] = []
        for _ in 0..<(width * height) { bgra += [blue, green, red, 255] }
        try renderer.setSource(gpu.makeLease(bgra: bgra, width: width, height: height))
        let target = try gpu.makeTarget(width: width, height: height)
        let texture = try #require(target.renderPassDescriptor.colorAttachments[0].texture)

        // Off by default: nothing built, nothing allocated.
        let first = renderer.draw(targetPixelSize: (width, height), displayScale: 2) { target }
        #expect(first == .submitted(frameID: 1))
        let unfrosted = try await gpu.readBack(texture)
        #expect(renderer.frostMemoryBytes == 0)
        #expect(renderer.frostPyramids.counters == FrostPyramidRing.Counters())
        #expect(renderer.frostPyramids.current == nil)
        #expect(metrics.counts.pyramidBuilds == 0 && metrics.counts.pyramidReuses == 0)
        #expect(try GlassFrost.none.normalized().isNone)

        // Requesting frost builds one pyramid, and a second draw of the same
        // frame reuses it. The glass shader does not read the pyramid yet, so
        // the picture is byte for byte the one without frost.
        try renderer.setFrost(GlassFrost(sigma: 8))
        for _ in 0..<2 {
            #expect(renderer.draw(targetPixelSize: (width, height), displayScale: 2) { target } == .submitted(frameID: 1))
        }
        let frosted = try await gpu.readBack(texture)
        #expect(frosted.bgra == unfrosted.bgra)
        #expect(metrics.counts.pyramidBuilds == 1)
        #expect(metrics.counts.pyramidReuses == 1)
        // Five levels (16 px of blur is past the fourth level's 12.2 px) of a
        // 160 x 96 region: 80 x 48, 40 x 24, 20 x 12, 10 x 6 and 5 x 3 texels
        // at 8 bytes.
        let expectedBytes = 8 * (80 * 48 + 40 * 24 + 20 * 12 + 10 * 6 + 5 * 3)
        #expect(renderer.frostMemoryBytes == expectedBytes)
        #expect(metrics.frostMemoryBytes == expectedBytes)
        #expect(renderer.frostPyramids.counters.allocations == 1)

        // A uniform source stays uniform: inside the region, past its edge,
        // far outside it, at every level and between two.
        let pyramid = try #require(renderer.frostPyramids.current)
        #expect(pyramid.plan.levelCount == 5)
        let positions: [SIMD2<Float>] = [[80, 48], [3, 4], [157, 93], [-40, -30], [400, 300]]
        let lods: [Float] = [0, 0.5, 1, 1.7, 2.2, 3, 3.5, 4, 9]
        let points = positions.flatMap { position in lods.map { (position: position, lod: $0) } }
        let samples = await renderer.frostPyramids.probe(pyramid, points: points)
        #expect(samples.count == points.count)
        let expected = SIMD3<Float>(linear(red), linear(green), linear(blue))
        for sample in samples {
            for channel in 0..<3 {
                // rgba16Float keeps about three decimal digits per level.
                #expect(abs(sample[channel] - expected[channel]) <= 0.005 * expected[channel] + 1e-4)
            }
        }

        // Trimming gives the memory back; none again builds nothing.
        renderer.trimFrostResources()
        #expect(renderer.frostMemoryBytes == 0)
        try renderer.setFrost(.none)
        let builds = renderer.frostPyramids.counters.builds
        #expect(renderer.draw(targetPixelSize: (width, height), displayScale: 2) { target } == .submitted(frameID: 1))
        #expect(renderer.frostPyramids.counters.builds == builds)
        #expect(renderer.frostMemoryBytes == 0)
    }
}
