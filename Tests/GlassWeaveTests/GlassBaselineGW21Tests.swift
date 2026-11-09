import CoreGraphics
import Foundation
import Metal
import Testing
@testable import GlassWeave

/// GW-22's safety test: with the thick-lens optics off (the default, and the
/// `.rim` profile whatever its other settings), the panel pass renders
/// exactly what the frozen GW-21 shader renders
/// (`Tests/GlassWeaveTests/Shaders/GlassBaselineGW21.metal`), byte for byte,
/// in the `base` pipeline variant; and a panel with a lens really differs.
@Suite(.timeLimit(.minutes(3)))
struct GlassBaselineGW21Tests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let parameters: GlassParameters
        let effectTime: Double
        var testDescription: String { name }
    }

    private static let light = GlassLight(
        emitters: [GlassLight.Emitter(
            placement: .band(angle: 180, reach: 1.2),
            colors: [.init(red: 1, green: 0.6, blue: 0.16), .init(red: 1, green: 0.38, blue: 0.82), .init(red: 0.22, green: 0.88, blue: 1)],
            intensity: 0.95, flow: 1, drift: 0.25
        )],
        piping: 0.85, timeOffset: 3
    )

    static let cases: [Case] = [
        Case(name: "GW-05 default parameters", parameters: GlassParameters(), effectTime: 0),
        Case(
            name: "inner light, no lens",
            parameters: GlassParameters(
                cornerRadius: 40, bezelWidth: 18, refraction: 0.8, edgeHighlight: 0.7,
                tint: GlassTint(red: 0.2, green: 0.3, blue: 0.5, strength: 0.3), light: light
            ),
            effectTime: 0.45
        ),
        Case(
            name: "rim profile with every other lens setting changed",
            parameters: GlassParameters(
                cornerRadius: 26, bezelWidth: 18, refraction: 0.8, edgeHighlight: 0.7,
                glow: GlassGlow(
                    colors: [.init(red: 0.25, green: 0.85, blue: 1, angle: 0), .init(red: 0.65, green: 0.35, blue: 1, angle: 180)],
                    rimWidth: 2, rimSoftness: 1.5, innerGlowRadius: 18, innerGlowIntensity: 0.7,
                    lightAngle: 30, directionality: 0.4, haloRadius: 24, haloIntensity: 0.9, pulsePeriod: 1.6, pulseDepth: 0.6
                ),
                light: light,
                lens: GlassLens(profile: .rim, thickness: 60, indexOfRefraction: 2.2, maximumOffset: 300, allowsFold: true)
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

    /// A renderer whose panel pass is the frozen GW-21 shader.
    private func gw21Renderer(_ gpu: GPUContext) throws -> GlassRenderer {
        try GlassRenderer(
            commandQueue: gpu.queue,
            library: BackgroundRenderer.makeLibrary(device: gpu.device),
            panelLibrary: gpu.device.makeDefaultLibrary(bundle: .module),
            panelVertex: "gw_gw21_glass_vertex", panelFragment: "gw_gw21_glass_fragment"
        )
    }

    @Test(arguments: cases)
    func `Without a lens the output is byte-identical to the GW-21 shader`(testCase: Case) async throws {
        let gpu = try GPUContext()
        let fixtures = [
            Fixture.coordinateGradient(width: 200, height: 160),
            Fixture.checkerboard(width: 200, height: 160, cell: 7, (250, 220, 30), (10, 30, 90)),
        ]
        for fixture in fixtures {
            let panel = GlassPanel(frame: CGRect(x: 30.5, y: 26.25, width: 131, height: 100), parameters: testCase.parameters)
            let renderer = try GlassRenderer(commandQueue: gpu.queue)
            let current = try await render(gpu, fixture, panel: panel, effectTime: testCase.effectTime, renderer: renderer)
            #expect(renderer.drawnVariants == [.base])
            let baseline = try await render(gpu, fixture, panel: panel, effectTime: testCase.effectTime, renderer: gw21Renderer(gpu))
            let differing = zip(current.bgra, baseline.bgra).count { $0 != $1 }
            #expect(differing == 0, "\(differing) bytes differ, at most by \(current.maximumDifference(from: baseline))")
            // Control: with a lens the optics variant draws, and it differs.
            var lensed = testCase.parameters
            lensed.bezelWidth = 40
            lensed.lens = GlassLens(profile: .circular, thickness: 60, indexOfRefraction: 1.8, maximumOffset: 200, allowsFold: true)
            let opticsRenderer = try GlassRenderer(commandQueue: gpu.queue)
            let optics = try await render(
                gpu, fixture, panel: GlassPanel(frame: panel.frame, parameters: lensed), effectTime: testCase.effectTime,
                renderer: opticsRenderer
            )
            #expect(opticsRenderer.drawnVariants == [.optics])
            #expect(optics.maximumDifference(from: baseline) > 10)
        }
    }
}
