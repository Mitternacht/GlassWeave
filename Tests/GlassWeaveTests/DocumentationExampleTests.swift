import CoreGraphics
import Metal
import Testing
@testable import GlassWeave

/// Runs the core example of the DocC catalog (DocumentationExamples.swift).
@Suite(.timeLimit(.minutes(1)))
struct DocumentationExampleTests {
    @Test func `The measuring example reports the GPU p95 of drawn frames`() async throws {
        let gpu = try GPUContext()
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        try renderer.setPanel(GlassPanel(frame: CGRect(x: 4, y: 4, width: 24, height: 16)))
        let report = measure(renderer)
        #expect(report() == nil, "Nothing drawn yet")

        try renderer.setSource(gpu.makePatternLease(width: 32, height: 24))
        let target = try gpu.makeTarget(width: 32, height: 24)
        #expect(renderer.draw(targetPixelSize: (32, 24), displayScale: 1, acquireTarget: { target }) == .submitted(frameID: 1))
        let metrics = try #require(renderer.metrics)
        let deadline = ContinuousClock.now + .seconds(5)
        while metrics.counts.commandBuffersCompleted < 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let milliseconds = report()
        // The example reports the recorder's own GPU p95, in milliseconds.
        let p95 = metrics.summary().gpu?.p95.components
        #expect(milliseconds == p95.map { Double($0.seconds) * 1_000 + Double($0.attoseconds) / 1e15 })
        if let milliseconds {
            #expect(milliseconds > 0 && milliseconds < 1_000)
        }
        #if !targetEnvironment(simulator)
        #expect(milliseconds != nil, "A Mac or device GPU reports command buffer times")
        #endif
        renderer.clearSource()
    }

    @Test func `The glow example glows amber at the top and violet below, with a clear middle`() async throws {
        let gpu = try GPUContext()
        // Odd sizes put the capsule's center on a pixel center, so the top
        // probe lies exactly at the first stop's angle.
        let frame = CGRect(x: 20, y: 20, width: 201, height: 81)
        let panel = glowingCapsule(frame: frame)
        #expect(panel.parameters.glow.colors.count == 2)
        let source = Fixture.uniform(width: 240, height: 120, (40, 42, 48))
        func render(_ panel: GlassPanel) async throws -> RenderedImage {
            let renderer = try GlassRenderer(commandQueue: gpu.queue)
            try renderer.setSource(gpu.makeLease(bgra: source.bgra, width: source.width, height: source.height))
            try renderer.setPanel(panel)
            #expect(renderer.panel?.parameters.glow == panel.parameters.glow, "In range: drawn as given")
            let target = try gpu.makeTarget(width: source.width, height: source.height)
            #expect(renderer.draw(targetPixelSize: (source.width, source.height), displayScale: 1) { target } == .submitted(frameID: 1))
            return try await gpu.readBack(try #require(target.renderPassDescriptor.colorAttachments[0].texture))
        }
        let image = try await render(panel)
        var plain = panel
        plain.parameters.glow = .none
        let withoutGlow = try await render(plain)
        // The top of the rim, facing the light, is the first stop's color.
        #expect(image.channels(x: 120, y: 21).largestDifference(from: SIMD3(0.2, 0.62, 1) * 255) <= 1)
        // The bottom leans violet: blue well above green.
        let bottom = image.channels(x: 120, y: 99)
        #expect(bottom.x > bottom.y + 40, "\(bottom)")
        // The middle is the glass without a glow.
        #expect(image.channels(x: 120, y: 60) == withoutGlow.channels(x: 120, y: 60))
        // And everything matches the CPU model.
        let g = GlassPanelGeometry(panel: try panel.normalized(), displayScale: 1)
        var worst = 0.0
        let reference = GlassReference(source: source, geometry: g)
        for y in 0..<source.height {
            for x in 0..<source.width {
                worst = max(worst, image.channels(x: x, y: y).largestDifference(from: reference.encodedColor(x: x, y: y)))
            }
        }
        #expect(worst <= 1)
    }
}
