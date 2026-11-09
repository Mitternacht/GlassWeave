import CoreGraphics
import Foundation
import Metal
import Testing
@testable import GlassWeave

/// GW-26's safety test: a rounded-rectangle panel (`GlassShape.roundedRectangle`,
/// the default) renders exactly what the frozen GW-25 shader renders
/// (`Tests/GlassWeaveTests/Shaders/GlassBaselineGW25.metal`), byte for byte,
/// in the `base`, `optics`, `lighting`, and `grounded` pipeline variants,
/// grounding pre-pass included; and a panel with a freeform shape really
/// differs, in the `shaped` variant.
@Suite(.timeLimit(.minutes(3)))
struct GlassBaselineGW25Tests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let parameters: GlassParameters
        let variant: GlassRenderer.PipelineVariant
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "GW-05 default parameters", parameters: GlassParameters(), variant: .base),
        Case(
            name: "glow, halo, interior and light",
            parameters: GlassParameters(
                cornerRadius: 26, bezelWidth: 18, refraction: 0.8, edgeHighlight: 0.7,
                tint: GlassTint(red: 0.2, green: 0.3, blue: 0.5, strength: 0.3),
                glow: GlassGlow(
                    colors: [.init(red: 0.25, green: 0.85, blue: 1, angle: 0), .init(red: 0.65, green: 0.35, blue: 1, angle: 180)],
                    rimWidth: 2, rimSoftness: 1.5, innerGlowRadius: 18, innerGlowIntensity: 0.7,
                    lightAngle: 30, directionality: 0.4, haloRadius: 24, haloIntensity: 0.9
                ),
                interior: GlassInterior(effect: .energy, colors: [.init(red: 1, green: 0.5, blue: 0.2)], intensity: 0.8, speed: 1),
                light: GlassLight(emitters: [GlassLight.Emitter(placement: .band(angle: 180, reach: 0.9), colors: [.init(red: 1, green: 0.4, blue: 0.7)], intensity: 0.8)], piping: 0.6)
            ),
            variant: .base
        ),
        Case(
            name: "thick lens with dispersion and an inlay",
            parameters: GlassParameters(
                cornerRadius: 50, bezelWidth: 40, refraction: 0.6, edgeHighlight: 0.8,
                lens: GlassLens(
                    profile: .squircle(exponent: 3), thickness: 40, indexOfRefraction: 1.5, maximumOffset: 80, allowsFold: true,
                    dispersion: 1, dispersionTaps: .sixTap,
                    inlays: [GlassLens.Inlay(x: 30, y: 0, radius: 24, height: 12, profile: .dome, rimLine: 0.7)]
                )
            ),
            variant: .optics
        ),
        Case(
            name: "chrome light model with bloom",
            parameters: GlassParameters(
                cornerRadius: 40, bezelWidth: 24, refraction: 0.5, edgeHighlight: 0.4,
                lighting: GlassLighting(
                    key: GlassLighting.Light(azimuth: 315, elevation: 50), finish: .prismatic(spread: 1, saturation: 0.9, phase: 0.1),
                    bloom: 0.5, bloomWidth: 8
                )
            ),
            variant: .lighting
        ),
        Case(
            name: "grounded: drop, contact, inner shadow and caustic, with a halo",
            parameters: GlassParameters(
                cornerRadius: 30, bezelWidth: 20, refraction: 0.6, edgeHighlight: 0.5,
                glow: GlassGlow(
                    colors: [.init(red: 1, green: 0.5, blue: 0.2, angle: 0)], rimWidth: 2, rimSoftness: 2,
                    haloRadius: 14, haloIntensity: 0.7
                ),
                grounding: GlassGrounding(
                    drop: .init(offset: 12, blur: 16, opacity: 0.6), contact: .init(width: 2, opacity: 0.5),
                    inner: .init(offset: 6, blur: 10, opacity: 0.5),
                    caustic: .init(offset: 6, radius: 6, intensity: 0.6)
                )
            ),
            variant: .grounded
        ),
    ]

    private func render(
        _ gpu: GPUContext, _ fixture: Fixture, panel: GlassPanel?, renderer: GlassRenderer
    ) async throws -> RenderedImage {
        try renderer.setSource(gpu.makeLease(bgra: fixture.bgra, width: fixture.width, height: fixture.height))
        try renderer.setPanel(panel)
        let target = try gpu.makeTarget(width: fixture.width, height: fixture.height)
        let outcome = renderer.draw(targetPixelSize: (fixture.width, fixture.height), displayScale: 1) { target }
        #expect(outcome == .submitted(frameID: renderer.currentFrame?.frameID ?? 0))
        return try await gpu.readBack(try #require(target.renderPassDescriptor.colorAttachments[0].texture))
    }

    /// A renderer whose panel pass is the frozen GW-25 shader.
    private func gw25Renderer(_ gpu: GPUContext) throws -> GlassRenderer {
        try GlassRenderer(
            commandQueue: gpu.queue,
            library: BackgroundRenderer.makeLibrary(device: gpu.device),
            panelLibrary: gpu.device.makeDefaultLibrary(bundle: .module),
            panelVertex: "gw_gw25_glass_vertex", panelFragment: "gw_gw25_glass_fragment",
            opticsConstant: "gw_gw25_optics_constant", lightingConstant: "gw_gw25_lighting_constant",
            groundingConstant: "gw_gw25_grounding_constant",
            groundingFunctions: (
                "gw_gw25_grounding_vertex", "gw_gw25_grounding_shadow_fragment", "gw_gw25_grounding_caustic_fragment"
            )
        )
    }

    @Test(arguments: cases)
    func `A rounded rectangle is byte-identical to the GW-25 shader`(testCase: Case) async throws {
        let gpu = try GPUContext()
        let fixtures = [
            Fixture.coordinateGradient(width: 200, height: 160),
            Fixture.checkerboard(width: 200, height: 160, cell: 7, (250, 220, 30), (10, 30, 90)),
        ]
        for fixture in fixtures {
            let panel = GlassPanel(frame: CGRect(x: 30.5, y: 26.25, width: 131, height: 100), parameters: testCase.parameters)
            let renderer = try GlassRenderer(commandQueue: gpu.queue)
            let current = try await render(gpu, fixture, panel: panel, renderer: renderer)
            #expect(renderer.drawnVariants == [testCase.variant])
            let baselineRenderer = try gw25Renderer(gpu)
            let baseline = try await render(gpu, fixture, panel: panel, renderer: baselineRenderer)
            #expect(renderer.groundingDrawCount == baselineRenderer.groundingDrawCount)
            let differing = zip(current.bgra, baseline.bgra).count { $0 != $1 }
            #expect(differing == 0, "\(differing) bytes differ, at most by \(current.maximumDifference(from: baseline))")
            // Control: the same panel with an ellipse outline is drawn by the
            // shaped variant, and the picture differs.
            var shapedParameters = testCase.parameters
            shapedParameters.shape = .ellipse
            let shapedRenderer = try GlassRenderer(commandQueue: gpu.queue)
            let shaped = try await render(gpu, fixture, panel: GlassPanel(frame: panel.frame, parameters: shapedParameters), renderer: shapedRenderer)
            #expect(shapedRenderer.drawnVariants == [.shaped])
            #expect(shaped.maximumDifference(from: baseline) > 10)
        }
    }
}
