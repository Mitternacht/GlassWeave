import CoreGraphics
import Foundation
import Metal
import Testing
import GlassWeaveShaderTypes
@testable import GlassWeave

/// GW-34's safety test: a panel with no touch, and a panel with only one of
/// frost, fill and touch, renders exactly what the frozen pre-GW-34 shader
/// renders (`Tests/GlassWeaveTests/Shaders/GlassBaselineGW34.metal`), byte for
/// byte, in the `base`, `optics`, `lighting`, `grounded`, `shaped`, `frosted`,
/// `filled` and `touched` pipeline variants; a frosted or filled panel with an
/// active touch style and no touch to answer is the same picture too. Control:
/// a touch that began inside a frosted panel draws in the `touchedFrosted`
/// variant, one inside a filled panel in the `touchedFilled` variant, and each
/// picture differs from the same panel without the touch.
@Suite(.timeLimit(.minutes(3)))
struct GlassBaselineGW34Tests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let parameters: GlassParameters
        let variant: GlassRenderer.PipelineVariant
        /// Whether a touch that began inside the panel is given (the touch-only case).
        var touched = false
        /// For a frosted or filled panel: the variant a touch that began inside it draws in.
        var touchedVariant: GlassRenderer.PipelineVariant?
        var testDescription: String { name }
    }

    static let frostParameters = GlassParameters(
        cornerRadius: 30, bezelWidth: 22, refraction: 0.6, edgeHighlight: 0.3,
        lens: GlassLens(profile: .squircle(exponent: 3), thickness: 24, indexOfRefraction: 1.5, maximumOffset: 44, dispersion: 0.3, dispersionTaps: .threeTap),
        lighting: GlassLighting.refined(azimuth: 315, environment: .studioDark),
        frost: GlassFrost(profile: .uniform, sigma: 4, grain: 0.3)
    )
    static let fillParameters = GlassParameters(
        cornerRadius: 36, bezelWidth: 22, refraction: 0.5, edgeHighlight: 0.3,
        lighting: GlassLighting.refined(azimuth: 315, environment: .studioDark),
        fill: GlassFill(
            region: .level(level: 0.5, tilt: 0), wallThickness: 4,
            colors: [.init(red: 0.42, green: 0.07, blue: 0.01), .init(red: 1, green: 0.38, blue: 0.04), .init(red: 1, green: 0.68, blue: 0.28)]
        )
    )

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
        Case(name: "frost with a lens and the refined light model", parameters: frostParameters, variant: .frosted, touchedVariant: .touchedFrosted),
        Case(name: "a level fill with the refined light model", parameters: fillParameters, variant: .filled, touchedVariant: .touchedFilled),
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

    /// A renderer whose panel pass is the frozen pre-GW-34 shader.
    private func frozenRenderer(_ gpu: GPUContext) throws -> GlassRenderer {
        try GlassRenderer(
            commandQueue: gpu.queue,
            library: BackgroundRenderer.makeLibrary(device: gpu.device),
            panelLibrary: gpu.device.makeDefaultLibrary(bundle: .module),
            panelVertex: "gw_gw34_glass_vertex", panelFragment: "gw_gw34_glass_fragment",
            opticsConstant: "gw_gw34_optics_constant", lightingConstant: "gw_gw34_lighting_constant",
            groundingConstant: "gw_gw34_grounding_constant", shapeConstant: "gw_gw34_shape_constant",
            frostConstant: "gw_gw34_frost_constant", fillConstant: "gw_gw34_fill_constant",
            touchConstant: "gw_gw34_touch_constant",
            groundingFunctions: (
                "gw_gw34_grounding_vertex", "gw_gw34_grounding_shadow_fragment", "gw_gw34_grounding_caustic_fragment"
            )
        )
    }

    @Test(arguments: cases)
    func `Panels without a touch, or with only one of frost, fill and touch, are byte-identical to the shader before GW-34`(testCase: Case) async throws {
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

            guard let touchedVariant = testCase.touchedVariant else { continue }
            var styled = testCase.parameters
            styled.touch = .standard
            let styledPanel = GlassPanel(frame: frame, parameters: styled)

            // An active touch style with no touch to answer is the same picture.
            let idleRenderer = try GlassRenderer(commandQueue: gpu.queue)
            let idle = try await render(gpu, fixture, panel: styledPanel, renderer: idleRenderer, touched: false)
            #expect(idleRenderer.drawnVariants == [testCase.variant])
            #expect(zip(idle.bgra, baseline.bgra).count { $0 != $1 } == 0)

            // Control: a touch that began inside the panel draws in the touched
            // frosted or touched filled variant, and the picture differs.
            let touchedRenderer = try GlassRenderer(commandQueue: gpu.queue)
            let touched = try await render(gpu, fixture, panel: styledPanel, renderer: touchedRenderer, touched: true)
            #expect(touchedRenderer.drawnVariants == [touchedVariant])
            #expect(touched.maximumDifference(from: current) > 4, "the touched picture does not differ from the untouched one")
        }
    }
}
