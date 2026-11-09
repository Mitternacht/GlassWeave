import CoreGraphics
import Foundation
import Metal
import Testing
@testable import GlassWeave

/// GW-21's safety test: with no inner light (the default), the panel pass
/// renders exactly what the frozen GW-20 shader renders
/// (`Tests/GlassWeaveTests/Shaders/GlassBaselineGW20.metal`), byte for byte.
@Suite(.timeLimit(.minutes(3)))
struct GlassBaselineGW20Tests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let parameters: GlassParameters
        let effectTime: Double
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "GW-05 default parameters", parameters: GlassParameters(), effectTime: 0),
        Case(
            name: "glow and interior, no light",
            parameters: GlassParameters(
                cornerRadius: 26, bezelWidth: 18, refraction: 0.8, edgeHighlight: 0.7,
                tint: GlassTint(red: 0.2, green: 0.3, blue: 0.5, strength: 0.3),
                glow: GlassGlow(
                    colors: [.init(red: 0.25, green: 0.85, blue: 1, angle: 0), .init(red: 0.65, green: 0.35, blue: 1, angle: 180)],
                    rimWidth: 2, rimSoftness: 1.5, innerGlowRadius: 18, innerGlowIntensity: 0.7,
                    lightAngle: 30, directionality: 0.4, haloRadius: 24, haloIntensity: 0.9, pulsePeriod: 1.6, pulseDepth: 0.6
                ),
                interior: GlassInterior(
                    effect: .energy,
                    colors: [.init(red: 0.1, green: 0.2, blue: 0.9), .init(red: 1, green: 1, blue: 1)],
                    intensity: 0.85, seed: 7, centerFade: 0.6
                ),
                light: .none
            ),
            effectTime: 0.45
        ),
    ]

    private func render(
        _ gpu: GPUContext, _ fixture: Fixture, panel: GlassPanel?, effectTime: Double, renderer: GlassRenderer
    ) async throws -> RenderedImage {
        try renderer.setSource(gpu.makeLease(bgra: fixture.bgra, width: fixture.width, height: fixture.height))
        try renderer.setPanel(panel)
        try renderer.setEffectTime(effectTime)
        let target = try gpu.makeTarget(width: fixture.width, height: fixture.height)
        let outcome = renderer.draw(targetPixelSize: (fixture.width, fixture.height), displayScale: 1) { target }
        #expect(outcome == .submitted(frameID: renderer.currentFrame?.frameID ?? 0))
        return try await gpu.readBack(try #require(target.renderPassDescriptor.colorAttachments[0].texture))
    }

    /// A renderer whose panel pass is the frozen GW-20 shader.
    private func gw20Renderer(_ gpu: GPUContext) throws -> GlassRenderer {
        try GlassRenderer(
            commandQueue: gpu.queue,
            library: BackgroundRenderer.makeLibrary(device: gpu.device),
            panelLibrary: gpu.device.makeDefaultLibrary(bundle: .module),
            panelVertex: "gw_gw20_glass_vertex", panelFragment: "gw_gw20_glass_fragment"
        )
    }

    @Test(arguments: cases)
    func `Without light the output is byte-identical to the GW-20 shader`(testCase: Case) async throws {
        let gpu = try GPUContext()
        let fixtures = [
            Fixture.coordinateGradient(width: 200, height: 160),
            Fixture.checkerboard(width: 200, height: 160, cell: 7, (250, 220, 30), (10, 30, 90)),
        ]
        for fixture in fixtures {
            let panel = GlassPanel(frame: CGRect(x: 30.5, y: 26.25, width: 131, height: 100), parameters: testCase.parameters)
            let current = try await render(
                gpu, fixture, panel: panel, effectTime: testCase.effectTime, renderer: GlassRenderer(commandQueue: gpu.queue)
            )
            let baseline = try await render(gpu, fixture, panel: panel, effectTime: testCase.effectTime, renderer: gw20Renderer(gpu))
            let differing = zip(current.bgra, baseline.bgra).count { $0 != $1 }
            #expect(differing == 0, "\(differing) bytes differ, at most by \(current.maximumDifference(from: baseline))")
            // Control: the frozen shader does draw the panel.
            let backgroundOnly = try await render(gpu, fixture, panel: nil, effectTime: 0, renderer: gw20Renderer(gpu))
            #expect(baseline.maximumDifference(from: backgroundOnly) > 20)
        }
    }
}
