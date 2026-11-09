import CoreGraphics
import Foundation
import Metal
import Testing
@testable import GlassWeave

/// GW-23's safety test: with the light model off (`GlassLighting.legacy`, the
/// default, whatever its other settings and whatever light offset the
/// renderer holds), the panel pass renders exactly what the frozen GW-22
/// shader renders (`Tests/GlassWeaveTests/Shaders/GlassBaselineGW22.metal`),
/// byte for byte, in the `base` and `optics` pipeline variants; and a panel
/// with a chrome finish really differs, in the `lighting` variant.
@Suite(.timeLimit(.minutes(3)))
struct GlassBaselineGW22Tests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let parameters: GlassParameters
        let variant: GlassRenderer.PipelineVariant
        var testDescription: String { name }
    }

    /// A light model that is configured but off.
    private static let configuredButOff = GlassLighting(
        isEnabled: false,
        key: GlassLighting.Light(azimuth: 200, elevation: 20, color: .init(red: 1, green: 0.5, blue: 0.2), intensity: 1, size: 0.9),
        rim: GlassLighting.Light(azimuth: 90, elevation: 70),
        environment: .studioDark, finish: .prismatic(spread: 3, saturation: 1, phase: 0.4),
        fresnel: 1, specular: 1, reflection: 1, bloom: 1, bloomWidth: 20, crispOutline: true
    )

    static let cases: [Case] = [
        Case(name: "GW-05 default parameters", parameters: GlassParameters(), variant: .base),
        Case(
            name: "glow and tint, light model configured but off",
            parameters: GlassParameters(
                cornerRadius: 26, bezelWidth: 18, refraction: 0.8, edgeHighlight: 0.7,
                tint: GlassTint(red: 0.2, green: 0.3, blue: 0.5, strength: 0.3),
                glow: GlassGlow(
                    colors: [.init(red: 0.25, green: 0.85, blue: 1, angle: 0), .init(red: 0.65, green: 0.35, blue: 1, angle: 180)],
                    rimWidth: 2, rimSoftness: 1.5, innerGlowRadius: 18, innerGlowIntensity: 0.7,
                    lightAngle: 30, directionality: 0.4, haloRadius: 24, haloIntensity: 0.9
                ),
                lighting: configuredButOff
            ),
            variant: .base
        ),
        Case(
            name: "thick lens with dispersion and an inlay, light model configured but off",
            parameters: GlassParameters(
                cornerRadius: 50, bezelWidth: 40, refraction: 0.6, edgeHighlight: 0.8,
                lens: GlassLens(
                    profile: .squircle(exponent: 3), thickness: 40, indexOfRefraction: 1.5, maximumOffset: 80, allowsFold: true,
                    dispersion: 1, dispersionTaps: .sixTap,
                    inlays: [GlassLens.Inlay(x: 30, y: 0, radius: 24, height: 12, profile: .dome, rimLine: 0.7)]
                ),
                lighting: configuredButOff
            ),
            variant: .optics
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

    /// A renderer whose panel pass is the frozen GW-22 shader.
    private func gw22Renderer(_ gpu: GPUContext) throws -> GlassRenderer {
        try GlassRenderer(
            commandQueue: gpu.queue,
            library: BackgroundRenderer.makeLibrary(device: gpu.device),
            panelLibrary: gpu.device.makeDefaultLibrary(bundle: .module),
            panelVertex: "gw_gw22_glass_vertex", panelFragment: "gw_gw22_glass_fragment",
            opticsConstant: "gw_gw22_optics_constant"
        )
    }

    @Test(arguments: cases)
    func `Without the light model the output is byte-identical to the GW-22 shader`(testCase: Case) async throws {
        let gpu = try GPUContext()
        let fixtures = [
            Fixture.coordinateGradient(width: 200, height: 160),
            Fixture.checkerboard(width: 200, height: 160, cell: 7, (250, 220, 30), (10, 30, 90)),
        ]
        for fixture in fixtures {
            let panel = GlassPanel(frame: CGRect(x: 30.5, y: 26.25, width: 131, height: 100), parameters: testCase.parameters)
            let renderer = try GlassRenderer(commandQueue: gpu.queue)
            // The light offset moves only light terms: with the light model
            // off it changes nothing.
            try renderer.setLightOffset(azimuth: 117, elevation: 21)
            let current = try await render(gpu, fixture, panel: panel, renderer: renderer)
            #expect(renderer.drawnVariants == [testCase.variant])
            let baseline = try await render(gpu, fixture, panel: panel, renderer: gw22Renderer(gpu))
            let differing = zip(current.bgra, baseline.bgra).count { $0 != $1 }
            #expect(differing == 0, "\(differing) bytes differ, at most by \(current.maximumDifference(from: baseline))")
            // Control: with a chrome finish the lighting variant draws, and it differs.
            var lit = testCase.parameters
            lit.lighting = GlassLighting(finish: .chrome, bloom: 0.5)
            let litRenderer = try GlassRenderer(commandQueue: gpu.queue)
            let lighted = try await render(gpu, fixture, panel: GlassPanel(frame: panel.frame, parameters: lit), renderer: litRenderer)
            #expect(litRenderer.drawnVariants == [.lighting])
            #expect(lighted.maximumDifference(from: baseline) > 10)
        }
    }
}
