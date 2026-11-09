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
}
