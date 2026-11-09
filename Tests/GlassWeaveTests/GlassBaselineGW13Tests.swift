import CoreGraphics
import Foundation
import Metal
import Testing
import GlassWeaveShaderTypes
@testable import GlassWeave

/// GW-13's safety test: every panel that is not a merge renders exactly what the
/// frozen pre-merge shader renders
/// (`Tests/GlassWeaveTests/Shaders/GlassBaselineGW13.metal`, the shader after
/// GW-12), byte for byte, in the `base`, `optics`, `lighting`, `grounded`,
/// `shaped` and `frosted` pipeline variants. The shaped cases include a
/// single-primitive blob and a two-primitive blob with no interior blend, the
/// existing blob path that a merge reuses. Control: the merged shape of a
/// `GlassSurfaceMerge` draws in the `shaped` variant and differs from a single
/// shape, and its interior blend changes the picture; the merge's progress
/// follows the normalization rule (a NaN throws naming `mergeProgress`, a
/// finite value clamps).
@Suite(.timeLimit(.minutes(3)))
struct GlassBaselineGW13Tests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let parameters: GlassParameters
        let variant: GlassRenderer.PipelineVariant
        var testDescription: String { name }
    }

    private static let look = GlassLighting.refined(azimuth: 315, environment: .studioLight)
    private static let lens = GlassLens(
        profile: .dome, thickness: 30, indexOfRefraction: 1.5, maximumOffset: 60, dispersion: 0.5, dispersionTaps: .threeTap
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
            name: "a single-circle blob with a lens and the refined light model",
            parameters: GlassParameters(
                cornerRadius: 30, bezelWidth: 22, refraction: 0.6, edgeHighlight: 0.3, lens: lens, lighting: look,
                shape: .blob(GlassBlob(primitives: [.circle(center: .zero, radius: 0.9)], smoothness: 0.25))
            ),
            variant: .shaped
        ),
        Case(
            name: "a two-part blob with no interior blend",
            parameters: GlassParameters(
                cornerRadius: 30, bezelWidth: 22, refraction: 0.6, edgeHighlight: 0.3, lens: lens, lighting: look,
                shape: .blob(GlassBlob(
                    primitives: [.circle(center: CGPoint(x: -0.55, y: 0), radius: 0.5), .capsule(from: CGPoint(x: 0.1, y: 0), to: CGPoint(x: 0.6, y: 0), radius: 0.5)],
                    smoothness: 0.5
                ))
            ),
            variant: .shaped
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

    /// A renderer whose panel pass is the frozen pre-merge shader.
    private func frozenRenderer(_ gpu: GPUContext) throws -> GlassRenderer {
        try GlassRenderer(
            commandQueue: gpu.queue,
            library: BackgroundRenderer.makeLibrary(device: gpu.device),
            panelLibrary: gpu.device.makeDefaultLibrary(bundle: .module),
            panelVertex: "gw_gw13_glass_vertex", panelFragment: "gw_gw13_glass_fragment",
            opticsConstant: "gw_gw13_optics_constant", lightingConstant: "gw_gw13_lighting_constant",
            groundingConstant: "gw_gw13_grounding_constant", shapeConstant: "gw_gw13_shape_constant",
            frostConstant: "gw_gw13_frost_constant", fillConstant: "gw_gw13_fill_constant",
            touchConstant: "gw_gw13_touch_constant",
            groundingFunctions: (
                "gw_gw13_grounding_vertex", "gw_gw13_grounding_shadow_fragment", "gw_gw13_grounding_caustic_fragment"
            )
        )
    }

    @Test(arguments: cases)
    func `A panel that is not a merge is byte-identical to the shader before the merge`(testCase: Case) async throws {
        #expect(MemoryLayout<GWShapeUniforms>.size == 336)
        #expect(MemoryLayout<GWGlassUniforms>.size == 1776)
        let gpu = try GPUContext()
        let fixtures = [
            Fixture.coordinateGradient(width: 200, height: 160),
            Fixture.checkerboard(width: 200, height: 160, cell: 7, (250, 220, 30), (10, 30, 90)),
        ]
        let frame = CGRect(x: 30.5, y: 26.25, width: 131, height: 100)
        for fixture in fixtures {
            let panel = GlassPanel(frame: frame, parameters: testCase.parameters)
            let renderer = try GlassRenderer(commandQueue: gpu.queue)
            let current = try await render(gpu, fixture, panel: panel, renderer: renderer)
            #expect(renderer.drawnVariants == [testCase.variant])
            let baselineRenderer = try frozenRenderer(gpu)
            let baseline = try await render(gpu, fixture, panel: panel, renderer: baselineRenderer)
            #expect(baselineRenderer.drawnVariants == [testCase.variant])
            #expect(renderer.groundingDrawCount == baselineRenderer.groundingDrawCount)
            let differing = zip(current.bgra, baseline.bgra).count { $0 != $1 }
            #expect(differing == 0, "\(differing) bytes differ, at most by \(current.maximumDifference(from: baseline))")
        }
    }

    @Test
    func `A merged shape draws, differs, and follows the normalization rule`() async throws {
        let gpu = try GPUContext()
        let fixture = Fixture.checkerboard(width: 200, height: 160, cell: 7, (250, 220, 30), (10, 30, 90))
        let frame = CGRect(x: 30.5, y: 26.25, width: 131, height: 100)
        func parameters(_ shape: GlassShape) -> GlassParameters {
            GlassParameters(
                cornerRadius: 30, bezelWidth: 22, refraction: 0.6, edgeHighlight: 0.3, lens: Self.lens, lighting: Self.look, shape: shape
            )
        }
        let left = CGPoint(x: -0.8, y: 0), right = CGPoint(x: 0.8, y: 0)
        let merge = GlassSurfaceMerge(
            first: .init(separate: .circle(center: left, radius: 0.5), merged: .capsule(from: left, to: CGPoint(x: 0.3, y: 0), radius: 0.6)),
            second: .init(separate: .circle(center: right, radius: 0.5), merged: .capsule(from: right, to: CGPoint(x: -0.3, y: 0), radius: 0.6))
        )
        let single = try await render(
            gpu, fixture, panel: GlassPanel(frame: frame, parameters: parameters(.blob(GlassBlob(primitives: [.circle(center: left, radius: 0.5)])))),
            renderer: try GlassRenderer(commandQueue: gpu.queue)
        )
        let mergedRenderer = try GlassRenderer(commandQueue: gpu.queue)
        let merged = try await render(
            gpu, fixture, panel: GlassPanel(frame: frame, parameters: parameters(try merge.shape(progress: 0.5))), renderer: mergedRenderer
        )
        #expect(mergedRenderer.drawnVariants == [.shaped])
        #expect(merged.maximumDifference(from: single) > 4)

        // The interior blend changes the picture; without it the blob is the
        // plain smooth union.
        var plain = merge
        plain.interiorSmoothness = 0
        let plainImage = try await render(
            gpu, fixture, panel: GlassPanel(frame: frame, parameters: parameters(try plain.shape(progress: 0.5))),
            renderer: try GlassRenderer(commandQueue: gpu.queue)
        )
        #expect(merged.maximumDifference(from: plainImage) > 0)

        // The progress follows the normalization rule.
        #expect(throws: GlassParameterError.nonFiniteShape(.mergeProgress)) { try merge.shape(progress: .nan) }
        #expect(throws: GlassParameterError.nonFiniteShape(.mergeProgress)) { try merge.blob(progress: .infinity) }
        #expect(try merge.blob(progress: 7) == merge.blob(progress: 1))
        #expect(try merge.blob(progress: -3) == merge.blob(progress: 0))
        #expect(try merge.blob(progress: 0).smoothness == 0)
        #expect(try merge.blob(progress: 0.5) == merge.blob(progress: 0.5))
    }
}
