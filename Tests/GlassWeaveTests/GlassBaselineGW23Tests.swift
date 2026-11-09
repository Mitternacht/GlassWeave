import CoreGraphics
import Foundation
import Metal
import Testing
@testable import GlassWeave

/// GW-25's safety test: with grounding off (`GlassGrounding.none`, the
/// default, whatever its other settings), the panel pass renders exactly what
/// the frozen GW-23 shader renders
/// (`Tests/GlassWeaveTests/Shaders/GlassBaselineGW23.metal`), byte for byte,
/// in the `base`, `optics`, and `lighting` pipeline variants, and draws no
/// pre-pass quad; and a grounded panel really differs, in the `grounded`
/// variant.
@Suite(.timeLimit(.minutes(3)))
struct GlassBaselineGW23Tests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let parameters: GlassParameters
        let variant: GlassRenderer.PipelineVariant
        var testDescription: String { name }
    }

    /// Grounding that is configured but off.
    private static let configuredButOff = GlassGrounding(
        isEnabled: false,
        drop: .init(offset: 30, blur: 40, spread: 4, opacity: 1, color: .black),
        contact: .init(width: 3, opacity: 1),
        inner: .init(offset: 8, blur: 12, opacity: 1),
        caustic: .init(offset: 10, radius: 12, intensity: 1, dispersion: 1, spectrum: 1),
        lightAzimuth: 200, lightElevation: 20
    )

    static let cases: [Case] = [
        Case(name: "GW-05 default parameters", parameters: GlassParameters(), variant: .base),
        Case(
            name: "glow and tint, grounding configured but off",
            parameters: GlassParameters(
                cornerRadius: 26, bezelWidth: 18, refraction: 0.8, edgeHighlight: 0.7,
                tint: GlassTint(red: 0.2, green: 0.3, blue: 0.5, strength: 0.3),
                glow: GlassGlow(
                    colors: [.init(red: 0.25, green: 0.85, blue: 1, angle: 0), .init(red: 0.65, green: 0.35, blue: 1, angle: 180)],
                    rimWidth: 2, rimSoftness: 1.5, innerGlowRadius: 18, innerGlowIntensity: 0.7,
                    lightAngle: 30, directionality: 0.4, haloRadius: 24, haloIntensity: 0.9
                ),
                grounding: configuredButOff
            ),
            variant: .base
        ),
        Case(
            name: "thick lens with dispersion and an inlay, grounding configured but off",
            parameters: GlassParameters(
                cornerRadius: 50, bezelWidth: 40, refraction: 0.6, edgeHighlight: 0.8,
                lens: GlassLens(
                    profile: .squircle(exponent: 3), thickness: 40, indexOfRefraction: 1.5, maximumOffset: 80, allowsFold: true,
                    dispersion: 1, dispersionTaps: .sixTap,
                    inlays: [GlassLens.Inlay(x: 30, y: 0, radius: 24, height: 12, profile: .dome, rimLine: 0.7)]
                ),
                grounding: configuredButOff
            ),
            variant: .optics
        ),
        Case(
            name: "chrome light model with bloom, grounding configured but off",
            parameters: GlassParameters(
                cornerRadius: 40, bezelWidth: 24, refraction: 0.5, edgeHighlight: 0.4,
                lighting: GlassLighting(
                    key: GlassLighting.Light(azimuth: 315, elevation: 50), finish: .prismatic(spread: 1, saturation: 0.9, phase: 0.1),
                    bloom: 0.5, bloomWidth: 8
                ),
                grounding: configuredButOff
            ),
            variant: .lighting
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

    /// A renderer whose panel pass is the frozen GW-23 shader.
    private func gw23Renderer(_ gpu: GPUContext) throws -> GlassRenderer {
        try GlassRenderer(
            commandQueue: gpu.queue,
            library: BackgroundRenderer.makeLibrary(device: gpu.device),
            panelLibrary: gpu.device.makeDefaultLibrary(bundle: .module),
            panelVertex: "gw_gw23_glass_vertex", panelFragment: "gw_gw23_glass_fragment",
            opticsConstant: "gw_gw23_optics_constant", lightingConstant: "gw_gw23_lighting_constant"
        )
    }

    @Test(arguments: cases)
    func `Without grounding the output is byte-identical to the GW-23 shader`(testCase: Case) async throws {
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
            #expect(renderer.groundingDrawCount == 0)
            let baseline = try await render(gpu, fixture, panel: panel, renderer: gw23Renderer(gpu))
            let differing = zip(current.bgra, baseline.bgra).count { $0 != $1 }
            #expect(differing == 0, "\(differing) bytes differ, at most by \(current.maximumDifference(from: baseline))")
            // Control: with grounding on, the grounded variant draws its
            // pre-pass, and the picture differs.
            var grounded = testCase.parameters
            grounded.grounding = GlassGrounding(
                drop: .init(offset: 12, blur: 16, opacity: 0.6), contact: .init(width: 2, opacity: 0.5),
                caustic: .init(offset: 6, radius: 6, intensity: 0.6)
            )
            let groundedRenderer = try GlassRenderer(commandQueue: gpu.queue)
            let shadowed = try await render(gpu, fixture, panel: GlassPanel(frame: panel.frame, parameters: grounded), renderer: groundedRenderer)
            #expect(groundedRenderer.drawnVariants == [.grounded])
            #expect(groundedRenderer.groundingDrawCount == 2)
            #expect(shadowed.maximumDifference(from: baseline) > 10)
        }
    }
}
