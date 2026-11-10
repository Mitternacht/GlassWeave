import CoreGraphics
import Foundation
import Metal
import Testing
import GlassWeaveShaderTypes
@testable import GlassWeave

/// GW-30's safety test: the default, opaque renderer draws exactly what the
/// frozen pre-overlay shader draws
/// (`Tests/GlassWeaveTests/Shaders/GlassBaselineGW30.metal`), byte for byte, in
/// the `base`, `optics`, `lighting`, `grounded`, `shaped`, `frosted`, `filled` and
/// `touched` pipeline variants. Control: the same panel in a renderer made with
/// ``GlassRenderer/Mode/overlay`` draws in the `overlay` variant, leaves alpha 0
/// outside the panel, has alpha inside it, and differs from the opaque picture.
@Suite(.timeLimit(.minutes(3)))
struct GlassBaselineGW30Tests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let parameters: GlassParameters
        let variant: GlassRenderer.PipelineVariant
        /// Whether a touch that began inside the panel is given.
        var touched = false
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
            name: "thick lens, six-tap dispersion and an inlay",
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
            name: "refined light model with bloom",
            parameters: GlassParameters(
                cornerRadius: 40, bezelWidth: 24, refraction: 0.5, edgeHighlight: 0.4,
                lighting: GlassLighting.refined(azimuth: 315, environment: .studioDark)
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
        Case(
            name: "an ellipse with the refined light model and a lens",
            parameters: GlassParameters(
                cornerRadius: 30, bezelWidth: 22, refraction: 0.6, edgeHighlight: 0.3,
                lens: GlassLens(profile: .dome, thickness: 30, indexOfRefraction: 1.5, maximumOffset: 60, dispersion: 0.5, dispersionTaps: .threeTap),
                lighting: GlassLighting.refined(azimuth: 315, environment: .studioLight),
                shape: .ellipse
            ),
            variant: .shaped
        ),
        Case(
            name: "frost with a lens and the refined light model",
            parameters: GlassParameters(
                cornerRadius: 30, bezelWidth: 22, refraction: 0.6, edgeHighlight: 0.3,
                lens: GlassLens(profile: .squircle(exponent: 3), thickness: 24, indexOfRefraction: 1.5, maximumOffset: 44, dispersion: 0.3, dispersionTaps: .threeTap),
                lighting: GlassLighting.refined(azimuth: 315, environment: .studioDark),
                frost: GlassFrost(profile: .uniform, sigma: 4, grain: 0.3)
            ),
            variant: .frosted
        ),
        Case(
            name: "a gel fill with the refined light model",
            parameters: GlassParameters(
                cornerRadius: 36, bezelWidth: 22, refraction: 0.5, edgeHighlight: 0.3,
                lighting: GlassLighting.refined(azimuth: 315, environment: .studioDark),
                fill: GlassFill(region: .gel(.blob(GlassBlob(primitives: [.circle(center: .zero, radius: 0.5)]))), wallThickness: 4)
            ),
            variant: .filled
        ),
        Case(
            name: "a touch response",
            parameters: GlassParameters(cornerRadius: 30, bezelWidth: 20, refraction: 0.6, edgeHighlight: 0.4, touch: .standard),
            variant: .touched, touched: true
        ),
    ]

    private func render(
        _ gpu: GPUContext, _ fixture: Fixture, panel: GlassPanel, renderer: GlassRenderer, touched: Bool
    ) async throws -> RenderedImage {
        try renderer.setSource(gpu.makeLease(bgra: fixture.bgra, width: fixture.width, height: fixture.height))
        try renderer.setPanel(panel)
        if touched {
            try renderer.setEffectTime(0.2)
            try renderer.setTouches([GlassTouchPoint(origin: CGPoint(x: panel.frame.midX, y: panel.frame.midY), beganAt: 0)])
        }
        let target = try gpu.makeTarget(width: fixture.width, height: fixture.height)
        let outcome = renderer.draw(targetPixelSize: (fixture.width, fixture.height), displayScale: 1) { target }
        #expect(outcome == .submitted(frameID: renderer.currentFrame?.frameID ?? 0))
        return try await gpu.readBack(try #require(target.renderPassDescriptor.colorAttachments[0].texture))
    }

    /// A renderer whose panel pass is the frozen pre-overlay shader.
    private func frozenRenderer(_ gpu: GPUContext) throws -> GlassRenderer {
        try GlassRenderer(
            commandQueue: gpu.queue,
            library: BackgroundRenderer.makeLibrary(device: gpu.device),
            panelLibrary: gpu.device.makeDefaultLibrary(bundle: .module),
            panelVertex: "gw_gw30_glass_vertex", panelFragment: "gw_gw30_glass_fragment",
            opticsConstant: "gw_gw30_optics_constant", lightingConstant: "gw_gw30_lighting_constant",
            groundingConstant: "gw_gw30_grounding_constant", shapeConstant: "gw_gw30_shape_constant",
            frostConstant: "gw_gw30_frost_constant", fillConstant: "gw_gw30_fill_constant",
            touchConstant: "gw_gw30_touch_constant",
            groundingFunctions: (
                "gw_gw30_grounding_vertex", "gw_gw30_grounding_shadow_fragment", "gw_gw30_grounding_caustic_fragment"
            )
        )
    }

    @Test(arguments: cases)
    func `The opaque renderer is byte-identical to the shader before the overlay`(testCase: Case) async throws {
        let gpu = try GPUContext()
        let fixtures = [
            Fixture.coordinateGradient(width: 200, height: 160),
            Fixture.checkerboard(width: 200, height: 160, cell: 7, (250, 220, 30), (10, 30, 90)),
        ]
        for fixture in fixtures {
            let frame = CGRect(x: 30.5, y: 26.25, width: 131, height: 100)
            let panel = GlassPanel(frame: frame, parameters: testCase.parameters)
            let renderer = try GlassRenderer(commandQueue: gpu.queue)
            let current = try await render(gpu, fixture, panel: panel, renderer: renderer, touched: testCase.touched)
            #expect(renderer.drawnVariants == [testCase.variant])
            let baselineRenderer = try frozenRenderer(gpu)
            let baseline = try await render(gpu, fixture, panel: panel, renderer: baselineRenderer, touched: testCase.touched)
            #expect(baselineRenderer.drawnVariants == [testCase.variant])
            #expect(renderer.groundingDrawCount == baselineRenderer.groundingDrawCount)
            let differing = zip(current.bgra, baseline.bgra).count { $0 != $1 }
            #expect(differing == 0, "\(differing) bytes differ, at most by \(current.maximumDifference(from: baseline))")

            // Control: the overlay renderer draws the same panel in the overlay
            // variant: alpha 0 outside the panel and its halo and shadow, some
            // alpha inside, and a different picture. It needs no source.
            let overlayFixture = Fixture.uniform(width: 280, height: 240, (128, 128, 128))
            let overlayPanel = GlassPanel(frame: CGRect(x: 75.5, y: 66.25, width: 131, height: 100), parameters: testCase.parameters)
            let opaque = try await render(gpu, overlayFixture, panel: overlayPanel, renderer: try GlassRenderer(commandQueue: gpu.queue), touched: testCase.touched)
            let overlayRenderer = try GlassRenderer(commandQueue: gpu.queue, mode: .overlay)
            try overlayRenderer.setPanel(overlayPanel)
            let target = try gpu.makeTarget(width: overlayFixture.width, height: overlayFixture.height)
            let outcome = overlayRenderer.draw(targetPixelSize: (overlayFixture.width, overlayFixture.height), displayScale: 1) { target }
            guard case .submitted = outcome else {
                Issue.record("The overlay draw was not submitted: \(outcome)")
                continue
            }
            let overlay = try await gpu.readBack(try #require(target.renderPassDescriptor.colorAttachments[0].texture))
            #expect(overlayRenderer.drawnVariants == [.overlay])
            for (x, y) in [(2, 2), (277, 2), (2, 237), (277, 237)] {
                #expect(overlay.color(x: x, y: y).alpha == 0, "alpha outside the panel at \(x), \(y)")
            }
            let maximumAlpha = stride(from: 3, to: overlay.bgra.count, by: 4).map { overlay.bgra[$0] }.max() ?? 0
            #expect(maximumAlpha > 0, "no alpha inside the panel")
            #expect(zip(overlay.bgra, opaque.bgra).count { $0 != $1 } > 0)
        }
    }
}
