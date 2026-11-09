import CoreGraphics
import Foundation
import Metal
import Testing
@testable import GlassWeave
import GlassWeaveShaderTypes

/// GW-19's parameter boundary: `GlassInterior`'s units, ranges, defaults,
/// normalization, and phase, and its conversion to the GPU record.
struct GlassInteriorParameterTests {
    private static let frame = CGRect(x: 0, y: 0, width: 120, height: 80)
    private static let ramp: [GlassInterior.Color] = [
        .init(red: 0.1, green: 0.2, blue: 0.9), .init(red: 0.2, green: 0.8, blue: 1), .init(red: 1, green: 1, blue: 1),
    ]

    private func normalized(_ interior: GlassInterior) throws -> GlassInterior {
        try GlassPanel(frame: Self.frame, parameters: GlassParameters(interior: interior)).normalized().parameters.interior
    }

    @Test func `Interiors default to none, and the documented defaults hold`() {
        #expect(GlassParameters().interior == .none)
        #expect(GlassInterior.none.effect == .none && GlassInterior.none.colors.isEmpty)
        let interior = GlassInterior(effect: .energy, colors: Self.ramp)
        #expect(interior.intensity == 0.8)
        #expect(interior.speed == 1)
        #expect(interior.seed == 0)
        #expect(interior.centerFade == 1)
        #expect(GlassInterior.maximumColors == 3)
        #expect(GlassInterior.maximumSpeed == 3)
        #expect(GlassInterior.loopDuration == 64)
        #expect(GlassInterior.Effect.allCases == [.none, .energy, .rays, .embers])
    }

    @Test func `An interior is visible with an effect, a color, and an intensity, and animated only with a speed`() {
        #expect(GlassInterior(effect: .rays, colors: Self.ramp).isVisible)
        #expect(GlassInterior(effect: .rays, colors: Self.ramp).isAnimated)
        #expect(!GlassInterior(effect: .none, colors: Self.ramp).isVisible)
        #expect(!GlassInterior(effect: .embers, colors: []).isVisible)
        #expect(!GlassInterior(effect: .energy, colors: Self.ramp, intensity: 0).isVisible)
        #expect(!GlassInterior(effect: .energy, colors: Self.ramp, intensity: 0).isAnimated)
        let still = GlassInterior(effect: .energy, colors: Self.ramp, speed: 0)
        #expect(still.isVisible && !still.isAnimated)
        #expect(!GlassInterior.none.isAnimated)
    }

    @Test func `Values in range pass through normalization`() throws {
        let interior = GlassInterior(effect: .embers, colors: Self.ramp, intensity: 0.65, speed: 2.5, seed: .max, centerFade: 0.4)
        #expect(try normalized(interior) == interior)
    }

    @Test func `Out-of-range values are clamped and only three colors are kept`() throws {
        let high = try normalized(GlassInterior(
            effect: .rays,
            colors: [.init(red: 1.5, green: -0.2, blue: 0.5)] + Self.ramp,
            intensity: 4, speed: 9, seed: 3, centerFade: 2
        ))
        #expect(high.colors == [.init(red: 1, green: 0, blue: 0.5), Self.ramp[0], Self.ramp[1]])
        #expect(high.intensity == 1)
        #expect(high.speed == GlassInterior.maximumSpeed)
        #expect(high.centerFade == 1)
        #expect(high.seed == 3)
        let low = try normalized(GlassInterior(effect: .rays, colors: Self.ramp, intensity: -1, speed: -2, centerFade: -0.5))
        #expect(low.intensity == 0 && low.speed == 0 && low.centerFade == 0)
    }

    @Test func `An interior without an effect or colors normalizes to none`() throws {
        #expect(try normalized(GlassInterior(effect: .none, colors: Self.ramp, intensity: 1)) == .none)
        #expect(try normalized(GlassInterior(effect: .energy, colors: [])) == .none)
    }

    @Test(arguments: [
        GlassParameterError.Field.interiorColorRed, .interiorColorGreen, .interiorColorBlue,
        .interiorIntensity, .interiorSpeed, .interiorCenterFade,
    ])
    func `A non-finite value is rejected naming its field, even without an effect`(field: GlassParameterError.Field) {
        for value in [Double.nan, .infinity, -.infinity] {
            for effect in [GlassInterior.Effect.energy, .none] {
                var interior = GlassInterior(effect: effect, colors: Self.ramp)
                switch field {
                case .interiorColorRed: interior.colors[2].red = value
                case .interiorColorGreen: interior.colors[1].green = value
                case .interiorColorBlue: interior.colors[0].blue = value
                case .interiorIntensity: interior.intensity = value
                case .interiorSpeed: interior.speed = value
                default: interior.centerFade = value
                }
                let panel = GlassPanel(frame: Self.frame, parameters: GlassParameters(interior: interior))
                #expect(throws: GlassParameterError.nonFinite(field)) {
                    try panel.normalized()
                }
            }
        }
    }

    @Test func `The phase is effect time times speed, reduced into one loop`() {
        let interior = GlassInterior(effect: .energy, colors: Self.ramp, speed: 1.5)
        let cases: [(time: Double, phase: Double)] = [
            (0, 0), (2, 3), (-2, 61), (64 / 1.5, 0), (100, 150 - 128),
            // A long-running clock keeps its accuracy.
            (1e9 + 2, (1.5e9 + 3).truncatingRemainder(dividingBy: 64)),
        ]
        for (time, phase) in cases {
            #expect(abs(interior.phase(at: time) - phase) < 1e-9, "phase at \(time) s")
        }
        for time in [-1e-20, -0.0, 1e300, -1e300] {
            let phase = interior.phase(at: time)
            #expect(phase >= 0 && phase < GlassInterior.loopDuration, "phase at \(time) s is \(phase)")
        }
        #expect(interior.phase(at: .nan) == 0)
        #expect(interior.phase(at: .infinity) == 0)
        #expect(GlassInterior(effect: .energy, colors: Self.ramp, speed: 0).phase(at: 12345) == 0)
    }

    @Test func `The geometry converts the interior and uploads it`() throws {
        let interior = GlassInterior(effect: .embers, colors: Self.ramp, intensity: 0.7, speed: 2, seed: 0xfeed_beef, centerFade: 0.25)
        let panel = try GlassPanel(frame: Self.frame, parameters: GlassParameters(interior: interior)).normalized()
        let g = GlassPanelGeometry(panel: panel, displayScale: 3, effectTime: 40)
        let drawn = try #require(g.interior)
        #expect(drawn.effect == .embers)
        #expect(drawn.phase == 16, "40 s × 2 = 80 s, one loop of 64 s later")
        #expect(drawn.pixelsPerPoint == 3)
        #expect(abs(drawn.colorsLinear[0].x - GlowColorModel.decodeSRGB(0.1)) < 1e-12)
        let uniforms = g.uniforms(background: GWBackgroundUniformsForTests.zero, targetWidth: 10, targetHeight: 10)
        #expect(uniforms.interiorEffect == GWInteriorEffectEmbers.rawValue)
        #expect(uniforms.interiorColorCount == 3)
        #expect(uniforms.interiorSeed == 0xfeed_beef)
        #expect(uniforms.interiorIntensity == 0.7)
        #expect(uniforms.interiorPhase == 16)
        #expect(uniforms.interiorCenterFade == 0.25)
        #expect(uniforms.interiorPixelsPerPoint == 3)
        #expect(uniforms.interiorColor2 == SIMD4<Float>(1, 1, 1, 0))
        #expect(uniforms.padding6 == 0)
        // Without an interior (or one that draws nothing) every interior
        // field is zero, so the shader skips it.
        for none in [GlassInterior.none, GlassInterior(effect: .energy, colors: Self.ramp, intensity: 0)] {
            let plain = GlassPanelGeometry(
                panel: try GlassPanel(frame: Self.frame, parameters: GlassParameters(interior: none)).normalized(),
                displayScale: 3, effectTime: 40
            )
            #expect(plain.interior == nil)
            let record = plain.uniforms(background: GWBackgroundUniformsForTests.zero, targetWidth: 10, targetHeight: 10)
            #expect(record.interiorEffect == 0 && record.interiorColorCount == 0 && record.interiorSeed == 0)
            #expect(record.interiorPhase == 0 && record.interiorIntensity == 0 && record.interiorPixelsPerPoint == 0)
            #expect(record.interiorColor0 == .zero)
        }
    }

    @Test func `The renderer reports the interior it draws`() throws {
        let renderer = try GlassRenderer(commandQueue: GPUContext().queue)
        try renderer.setPanel(GlassPanel(frame: Self.frame, parameters: GlassParameters(
            interior: GlassInterior(effect: .rays, colors: Self.ramp + Self.ramp, intensity: 7, speed: -1)
        )))
        let drawn = try #require(renderer.panel?.parameters.interior)
        #expect(drawn.colors == Self.ramp && drawn.intensity == 1 && drawn.speed == 0)
        // A rejected value keeps the previous panel.
        #expect(throws: GlassParameterError.nonFinite(.interiorSpeed)) {
            try renderer.setPanel(GlassPanel(frame: Self.frame, parameters: GlassParameters(
                interior: GlassInterior(effect: .rays, colors: Self.ramp, speed: .nan)
            )))
        }
        #expect(renderer.panel?.parameters.interior == drawn)
    }
}

/// GW-19 on the GPU: the three interiors against the CPU model, their
/// bounds, center fade, determinism, loop, and byte identity with the GW-18
/// shader when there is no interior.
@Suite(.timeLimit(.minutes(3)))
struct GlassInteriorRenderTests {
    private func render(
        _ gpu: GPUContext, _ fixture: Fixture, panel: GlassPanel?, displayScale: Double = 1,
        effectTime: Double = 0, renderer: GlassRenderer? = nil
    ) async throws -> RenderedImage {
        let renderer = try renderer ?? GlassRenderer(commandQueue: gpu.queue)
        try renderer.setSource(gpu.makeLease(bgra: fixture.bgra, width: fixture.width, height: fixture.height))
        try renderer.setPanel(panel)
        try renderer.setEffectTime(effectTime)
        let target = try gpu.makeTarget(width: fixture.width, height: fixture.height)
        let outcome = renderer.draw(targetPixelSize: (fixture.width, fixture.height), displayScale: displayScale) { target }
        #expect(outcome == .submitted(frameID: renderer.currentFrame?.frameID ?? 0))
        let image = try await gpu.readBack(try #require(target.renderPassDescriptor.colorAttachments[0].texture))
        #expect(image.isFullyOpaque)
        return image
    }

    /// A renderer whose panel pass is the frozen GW-18 shader
    /// (`Tests/GlassWeaveTests/Shaders/GlassBaselineGW18.metal`).
    private func gw18Renderer(_ gpu: GPUContext) throws -> GlassRenderer {
        try GlassRenderer(
            commandQueue: gpu.queue,
            library: BackgroundRenderer.makeLibrary(device: gpu.device),
            panelLibrary: gpu.device.makeDefaultLibrary(bundle: .module),
            panelVertex: "gw_gw18_glass_vertex", panelFragment: "gw_gw18_glass_fragment"
        )
    }

    private func geometry(_ panel: GlassPanel, scale: Double = 1, effectTime: Double = 0) throws -> GlassPanelGeometry {
        GlassPanelGeometry(panel: try panel.normalized(), displayScale: scale, effectTime: effectTime)
    }

    private func differingBytes(_ a: RenderedImage, _ b: RenderedImage) -> Int {
        zip(a.bgra, b.bgra).count { $0 != $1 }
    }

    /// The largest per-channel difference from the CPU model, and how many
    /// channel values differ by more than one step.
    private func modelError(_ image: RenderedImage, _ reference: GlassReference) -> (worst: Double, overOneStep: Int) {
        var worst = 0.0, over = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let difference = image.channels(x: x, y: y).largestDifference(from: reference.encodedColor(x: x, y: y))
                worst = max(worst, difference)
                if difference > 1 { over += 1 }
            }
        }
        return (worst, over)
    }

    private static func pixel(_ x: Int, _ y: Int) -> SIMD2<Double> {
        SIMD2(Double(x) + 0.5, Double(y) + 0.5)
    }

    // MARK: Presets used across the tests

    static let blueRamp: [GlassInterior.Color] = [
        .init(red: 0.05, green: 0.2, blue: 0.85), .init(red: 0.2, green: 0.85, blue: 1), .init(red: 0.95, green: 0.98, blue: 1),
    ]
    static let fireRamp: [GlassInterior.Color] = [
        .init(red: 0.75, green: 0.08, blue: 0.02), .init(red: 1, green: 0.5, blue: 0.08), .init(red: 1, green: 0.92, blue: 0.55),
    ]
    static let sunRamp: [GlassInterior.Color] = [
        .init(red: 1, green: 0.55, blue: 0.1), .init(red: 1, green: 0.95, blue: 0.7),
    ]

    struct InteriorCase: CustomTestStringConvertible, Sendable {
        let name: String
        let frame: CGRect
        let parameters: GlassParameters
        let scale: Double
        var testDescription: String { name }
    }

    static let modelCases: [InteriorCase] = [
        InteriorCase(
            name: "energy in a circle with a pulsing halo",
            frame: CGRect(x: 40, y: 30, width: 121, height: 121),
            parameters: GlassParameters(
                cornerRadius: 999, bezelWidth: 14, refraction: 0.6, edgeHighlight: 0.4,
                glow: GlassGlow(colors: [.init(red: 0.3, green: 0.8, blue: 1)], innerGlowRadius: 16, innerGlowIntensity: 0.5,
                                haloRadius: 18, haloIntensity: 0.8, pulsePeriod: 1.5, pulseDepth: 0.5),
                interior: GlassInterior(effect: .energy, colors: blueRamp, intensity: 1, seed: 7)
            ),
            scale: 1
        ),
        InteriorCase(
            name: "rays in a tinted rounded rectangle, half faded",
            frame: CGRect(x: 25.5, y: 30.25, width: 150, height: 120),
            parameters: GlassParameters(
                cornerRadius: 24, bezelWidth: 16, refraction: 0.7, edgeHighlight: 0.5,
                tint: GlassTint(red: 0.1, green: 0.1, blue: 0.2, strength: 0.4),
                glow: GlassGlow(colors: [.init(red: 1, green: 0.7, blue: 0.2)], lightAngle: 0, directionality: 0.6),
                interior: GlassInterior(effect: .rays, colors: sunRamp, intensity: 0.9, seed: 3, centerFade: 0.5)
            ),
            scale: 1
        ),
        InteriorCase(
            name: "embers in a capsule with a halo the sparks rise into",
            frame: CGRect(x: 20, y: 70, width: 160, height: 64),
            parameters: GlassParameters(
                cornerRadius: 999, bezelWidth: 10, refraction: 0.5, edgeHighlight: 0.3,
                glow: GlassGlow(colors: [.init(red: 1, green: 0.45, blue: 0.1)], innerGlowRadius: 14, innerGlowIntensity: 0.4,
                                lightAngle: 0, directionality: 0.5, haloRadius: 36, haloIntensity: 0.6),
                interior: GlassInterior(effect: .embers, colors: fireRamp, intensity: 1, seed: 11, centerFade: 0.3)
            ),
            scale: 1
        ),
        InteriorCase(
            name: "energy at display scale 2, no glow, no fade",
            frame: CGRect(x: 10.25, y: 12.5, width: 80, height: 60),
            parameters: GlassParameters(
                cornerRadius: 18, bezelWidth: 8, refraction: 0.4, edgeHighlight: 0.5,
                interior: GlassInterior(effect: .energy, colors: [.init(red: 0.6, green: 0.3, blue: 1)], intensity: 0.85, seed: 99, centerFade: 0)
            ),
            scale: 2
        ),
    ]

    // MARK: Without an interior, the GW-18 output is unchanged

    struct Gw18Case: CustomTestStringConvertible, Sendable {
        let name: String
        let parameters: GlassParameters
        let effectTime: Double
        var testDescription: String { name }
    }

    static let gw18Cases: [Gw18Case] = {
        let glow = GlassGlow(
            colors: [.init(red: 0.25, green: 0.85, blue: 1, angle: 0), .init(red: 0.65, green: 0.35, blue: 1, angle: 180)],
            rimWidth: 2, rimSoftness: 1.5, innerGlowRadius: 18, innerGlowIntensity: 0.7,
            lightAngle: 30, directionality: 0.4, haloRadius: 24, haloIntensity: 0.9, pulsePeriod: 1.6, pulseDepth: 0.6
        )
        let parameters = { (glow: GlassGlow, interior: GlassInterior) in
            GlassParameters(cornerRadius: 26, bezelWidth: 18, refraction: 0.8, edgeHighlight: 0.7,
                            tint: GlassTint(red: 0.2, green: 0.3, blue: 0.5, strength: 0.3), glow: glow, interior: interior)
        }
        return [
            Gw18Case(name: "halo and pulse, no interior", parameters: parameters(glow, .none), effectTime: 0.45),
            Gw18Case(name: "an effect without colors", parameters: parameters(glow, GlassInterior(effect: .embers, colors: [])), effectTime: 0.45),
            Gw18Case(name: "colors without an effect", parameters: parameters(glow, GlassInterior(effect: .none, colors: blueRamp)), effectTime: 3),
            Gw18Case(name: "an interior at intensity 0", parameters: parameters(glow, GlassInterior(effect: .energy, colors: blueRamp, intensity: 0)), effectTime: 3),
            Gw18Case(name: "default parameters", parameters: GlassParameters(), effectTime: 0),
        ]
    }()

    @Test(arguments: gw18Cases)
    func `Without an interior the output is byte-identical to the GW-18 shader`(testCase: Gw18Case) async throws {
        let gpu = try GPUContext()
        let fixtures = [
            Fixture.coordinateGradient(width: 200, height: 160),
            Fixture.checkerboard(width: 200, height: 160, cell: 7, (250, 220, 30), (10, 30, 90)),
        ]
        for fixture in fixtures {
            let panel = GlassPanel(frame: CGRect(x: 30.5, y: 26.25, width: 131, height: 100), parameters: testCase.parameters)
            let current = try await render(gpu, fixture, panel: panel, effectTime: testCase.effectTime)
            let baseline = try await render(gpu, fixture, panel: panel, effectTime: testCase.effectTime, renderer: gw18Renderer(gpu))
            let differing = differingBytes(current, baseline)
            #expect(differing == 0, "\(differing) bytes differ, at most by \(current.maximumDifference(from: baseline))")
            // Control: the frozen shader does draw the panel.
            let backgroundOnly = try await render(gpu, fixture, panel: nil, renderer: gw18Renderer(gpu))
            #expect(baseline.maximumDifference(from: backgroundOnly) > 20)
        }
    }

    // MARK: The CPU model

    @Test(arguments: modelCases)
    func `Each interior matches the CPU model at several times`(testCase: InteriorCase) async throws {
        let gpu = try GPUContext()
        // A 1:1 source in pixels, so the model's pixel is the texel.
        let fixture = Fixture.coordinateGradient(width: 200, height: testCase.scale == 1 ? 180 : 160)
        let panel = GlassPanel(frame: testCase.frame, parameters: testCase.parameters)
        var lit = 0
        for time in [0.0, 1.37, 25.5, 63.99] {
            let image = try await render(gpu, fixture, panel: panel, displayScale: testCase.scale, effectTime: time)
            let g = try geometry(panel, scale: testCase.scale, effectTime: time)
            let reference = GlassReference(source: fixture, geometry: g)
            let error = modelError(image, reference)
            #expect(error.worst <= 1, "time \(time): worst \(error.worst), \(error.overOneStep) values over one step")
            // The model is finite everywhere, and the interior lights pixels.
            var nonFinite = 0
            for y in 0..<fixture.height {
                for x in 0..<fixture.width {
                    let c = reference.linearColor(x: x, y: y)
                    if !(c.x.isFinite && c.y.isFinite && c.z.isFinite) { nonFinite += 1 }
                    if g.coverage(at: Self.pixel(x, y)) > 0, g.interiorLight(at: Self.pixel(x, y)).alpha > 0.05 { lit += 1 }
                }
            }
            #expect(nonFinite == 0)
        }
        #expect(lit > 400, "The interior lights a visible area")
    }

    /// Small, thin, deep-faded, fast, and extreme-seed panels stay within the
    /// model and finite: no division by a zero size, no NaN.
    @Test func `Extreme panels and values stay finite and match the model`() async throws {
        let gpu = try GPUContext()
        let source = Fixture.coordinateGradient(width: 120, height: 90)
        let shapes: [(CGRect, Double)] = [
            (CGRect(x: 10, y: 10, width: 1, height: 1), 999),
            (CGRect(x: 5, y: 40, width: 110, height: 1.5), 999),
            (CGRect(x: 60, y: 2, width: 2, height: 85), 0),
            (CGRect(x: 30.3, y: 20.7, width: 61, height: 47), 0),
        ]
        for effect in [GlassInterior.Effect.energy, .rays, .embers] {
            for (frame, corner) in shapes {
                for (seed, time, fade) in [(UInt32.max, 63.999, 1.0), (0, 0, 0), (0x8000_0000, 1e7 + 0.3, 0.6)] {
                    let interior = GlassInterior(effect: effect, colors: Self.fireRamp, intensity: 1, speed: 3, seed: seed, centerFade: fade)
                    let glow = GlassGlow(colors: [.init(red: 0.9, green: 0.5, blue: 0.2)], haloRadius: 20, haloIntensity: 0.5)
                    let panel = GlassPanel(frame: frame, parameters: GlassParameters(cornerRadius: corner, glow: glow, interior: interior))
                    let image = try await render(gpu, source, panel: panel, effectTime: time)
                    let g = try geometry(panel, effectTime: time)
                    let reference = GlassReference(source: source, geometry: g)
                    let error = modelError(image, reference)
                    #expect(error.worst <= 1, "\(effect) \(frame) seed \(seed) time \(time): worst \(error.worst)")
                    var nonFinite = 0
                    for y in 0..<source.height {
                        for x in 0..<source.width {
                            let c = reference.linearColor(x: x, y: y)
                            if !(c.x.isFinite && c.y.isFinite && c.z.isFinite) { nonFinite += 1 }
                        }
                    }
                    #expect(nonFinite == 0)
                }
            }
        }
    }

    // MARK: Bounds

    /// Energy and rays never change a pixel the panel does not cover; embers
    /// change pixels outside the outline only above the panel's center line
    /// and within the halo radius, and none at all without a halo. Checked
    /// against the same panel without an interior at eight instants, for a
    /// rounded rectangle and a circle (whose curved sides leave sparks near
    /// them outside the outline below its center).
    @Test(arguments: [GlassInterior.Effect.energy, .rays, .embers])
    func `Nothing is drawn outside the shape except sparks within the halo`(effect: GlassInterior.Effect) async throws {
        let gpu = try GPUContext()
        let source = Fixture.uniform(width: 220, height: 200, (24, 26, 34))
        let shapes: [(CGRect, Double)] = [
            (CGRect(x: 50.5, y: 80.25, width: 120, height: 70), 30),
            (CGRect(x: 60, y: 60, width: 100, height: 100), 999),
        ]
        for (frame, corner) in shapes {
        for haloRadius in [0.0, 40] {
            let glow = GlassGlow(colors: [.init(red: 1, green: 0.5, blue: 0.15)], haloRadius: haloRadius, haloIntensity: 0.5)
            let interior = GlassInterior(effect: effect, colors: Self.fireRamp, intensity: 1, speed: 1, seed: 5, centerFade: 0)
            let panel = GlassPanel(frame: frame, parameters: GlassParameters(cornerRadius: corner, glow: glow, interior: interior))
            var plain = panel
            plain.parameters.interior = .none
            let g = try geometry(panel)
            var outsideChanged = 0, outsideAllowed = 0, insideChanged = 0
            for time in stride(from: 0.0, to: 16, by: 2) {
                let image = try await render(gpu, source, panel: panel, effectTime: time)
                let withoutInterior = try await render(gpu, source, panel: plain, effectTime: time)
                for y in 0..<source.height {
                    for x in 0..<source.width {
                        guard image.channels(x: x, y: y) != withoutInterior.channels(x: x, y: y) else { continue }
                        let p = Self.pixel(x, y)
                        if g.coverage(at: p) > 0 {
                            insideChanged += 1
                        } else if effect == .embers, haloRadius > 0, p.y < g.center.y, g.signedDistance(at: p) < haloRadius {
                            outsideAllowed += 1
                        } else {
                            outsideChanged += 1
                        }
                    }
                }
            }
            #expect(outsideChanged == 0, "\(effect), \(frame), halo \(haloRadius): \(outsideChanged) pixels changed outside the allowed region")
            #expect(insideChanged > 2000)
            if effect == .embers, haloRadius > 0 {
                #expect(outsideAllowed > 20, "Sparks rise past the top edge into the halo")
            } else {
                #expect(outsideAllowed == 0)
            }
        }
        }
    }

    /// At center fade 1, every pixel deeper than 85 % of half the shorter
    /// side is exactly the glass without an interior, at every instant; at
    /// center fade 0 the interior also lights the middle.
    @Test(arguments: [GlassInterior.Effect.energy, .rays, .embers])
    func `Center fade 1 keeps the middle exactly see-through`(effect: GlassInterior.Effect) async throws {
        let gpu = try GPUContext()
        let source = Fixture.coordinateGradient(width: 200, height: 180)
        let frame = CGRect(x: 20, y: 20, width: 161, height: 141)
        func panel(fade: Double) -> GlassPanel {
            GlassPanel(frame: frame, parameters: GlassParameters(
                cornerRadius: 999, interior: GlassInterior(effect: effect, colors: Self.blueRamp, intensity: 1, seed: 2, centerFade: fade)
            ))
        }
        var plain = panel(fade: 1)
        plain.parameters.interior = .none
        let g = try geometry(panel(fade: 1))
        var middle = 0, middleChanged = 0, middleLitWithoutFade = 0, outerChanged = 0
        for time in [0.0, 3.3, 9.1, 40.7] {
            let faded = try await render(gpu, source, panel: panel(fade: 1), effectTime: time)
            let unfaded = try await render(gpu, source, panel: panel(fade: 0), effectTime: time)
            let withoutInterior = try await render(gpu, source, panel: plain, effectTime: time)
            for y in 0..<source.height {
                for x in 0..<source.width {
                    let p = Self.pixel(x, y)
                    let w = g.interiorDepthFraction(at: p)
                    let same = faded.channels(x: x, y: y) == withoutInterior.channels(x: x, y: y)
                    if w >= 0.85 {
                        middle += 1
                        if !same { middleChanged += 1 }
                        if unfaded.channels(x: x, y: y) != withoutInterior.channels(x: x, y: y) { middleLitWithoutFade += 1 }
                    } else if w < 0.3, g.coverage(at: p) == 1, !same {
                        outerChanged += 1
                    }
                }
            }
        }
        #expect(middle > 1000)
        #expect(middleChanged == 0, "\(effect): \(middleChanged) middle pixels changed at center fade 1")
        #expect(middleLitWithoutFade > 30, "\(effect): at center fade 0 the middle is lit")
        #expect(outerChanged > 300, "\(effect): the outer part is unfaded")
    }

    // MARK: Light

    /// The interior is light: no channel inside the shape drops below the
    /// panel without an interior (beyond one step of dither).
    @Test(arguments: [GlassInterior.Effect.energy, .rays, .embers])
    func `The interior only adds light`(effect: GlassInterior.Effect) async throws {
        let gpu = try GPUContext()
        let source = Fixture.checkerboard(width: 200, height: 160, cell: 5, (250, 240, 235), (12, 40, 70))
        let panel = GlassPanel(frame: CGRect(x: 30, y: 20, width: 140, height: 120), parameters: GlassParameters(
            cornerRadius: 40, glow: GlassGlow(colors: [.init(red: 0.2, green: 0.6, blue: 1)], haloRadius: 16),
            interior: GlassInterior(effect: effect, colors: Self.fireRamp, intensity: 1, seed: 9, centerFade: 0)
        ))
        var plain = panel
        plain.parameters.interior = .none
        let image = try await render(gpu, source, panel: panel, effectTime: 2.5)
        let withoutInterior = try await render(gpu, source, panel: plain, effectTime: 2.5)
        var darker = 0, brighter = 0
        for y in 0..<source.height {
            for x in 0..<source.width {
                let a = image.channels(x: x, y: y), b = withoutInterior.channels(x: x, y: y)
                if (0..<3).contains(where: { a[$0] < b[$0] - 1 }) { darker += 1 }
                if a.sum() > b.sum() + 6 { brighter += 1 }
            }
        }
        #expect(darker == 0)
        #expect(brighter > 500)
    }

    // MARK: Time and seed

    @Test(arguments: [GlassInterior.Effect.energy, .rays, .embers])
    func `The same seed and time render the same bytes; other times and seeds differ`(effect: GlassInterior.Effect) async throws {
        let gpu = try GPUContext()
        let source = Fixture.uniform(width: 180, height: 150, (20, 22, 30))
        func panel(seed: UInt32) -> GlassPanel {
            GlassPanel(frame: CGRect(x: 30, y: 40, width: 120, height: 80), parameters: GlassParameters(
                cornerRadius: 28,
                glow: GlassGlow(colors: [.init(red: 1, green: 0.6, blue: 0.2)], haloRadius: 30),
                interior: GlassInterior(effect: effect, colors: Self.fireRamp, intensity: 1, seed: seed, centerFade: 0.5)
            ))
        }
        let first = try await render(gpu, source, panel: panel(seed: 4), effectTime: 5.25)
        // A fresh renderer and a different order of draws give the same bytes.
        _ = try await render(gpu, source, panel: panel(seed: 8), effectTime: 1)
        let second = try await render(gpu, source, panel: panel(seed: 4), effectTime: 5.25)
        #expect(differingBytes(first, second) == 0)
        let later = try await render(gpu, source, panel: panel(seed: 4), effectTime: 5.75)
        let otherSeed = try await render(gpu, source, panel: panel(seed: 5), effectTime: 5.25)
        #expect(differingBytes(first, later) > 300, "Half a second later the pattern moved")
        #expect(differingBytes(first, otherSeed) > 300, "Another seed is another pattern")
        // Speed scales time: speed 2 at t equals speed 1 at 2t, and speed 0
        // is the still frame at interior time 0 whatever the effect time.
        var fast = panel(seed: 4)
        fast.parameters.interior.speed = 2
        #expect(differingBytes(try await render(gpu, source, panel: fast, effectTime: 2.625), first) == 0)
        var still = panel(seed: 4)
        still.parameters.interior.speed = 0
        let stillLater = try await render(gpu, source, panel: still, effectTime: 77)
        #expect(differingBytes(try await render(gpu, source, panel: panel(seed: 4), effectTime: 0), stillLater) == 0)
    }

    /// The pattern is periodic over the loop: across the wrap from just
    /// before its end to its start, the image changes no more than over an
    /// ordinary millisecond of motion, while a jump of seconds changes it
    /// far more (a seam would change it as much as such a jump).
    @Test(arguments: [GlassInterior.Effect.energy, .rays, .embers])
    func `The loop has no seam`(effect: GlassInterior.Effect) async throws {
        let gpu = try GPUContext()
        let source = Fixture.uniform(width: 180, height: 150, (20, 22, 30))
        let panel = GlassPanel(frame: CGRect(x: 30, y: 40, width: 120, height: 80), parameters: GlassParameters(
            cornerRadius: 28,
            glow: GlassGlow(colors: [.init(red: 1, green: 0.6, blue: 0.2)], haloRadius: 30),
            interior: GlassInterior(effect: effect, colors: Self.fireRamp, intensity: 1, seed: 6, centerFade: 0)
        ))
        func change(_ a: Double, _ b: Double) async throws -> Int {
            let first = try await render(gpu, source, panel: panel, effectTime: a)
            let second = try await render(gpu, source, panel: panel, effectTime: b)
            return zip(first.bgra, second.bgra).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        }
        let loop = GlassInterior.loopDuration
        let acrossWrap = try await change(loop - 0.001, 0)
        var ordinary: [Int] = []
        for time in [5.0, 17.25, 33.5, 50.75] {
            ordinary.append(try await change(time, time + 0.001))
        }
        let jump = try await change(0, 5)
        #expect(acrossWrap <= 2 * ordinary.max()!, "across the wrap \(acrossWrap), ordinary 1 ms steps \(ordinary)")
        #expect(ordinary.min()! > 0, "A millisecond moves the pattern")
        #expect(jump > 20 * acrossWrap, "a 5 s jump \(jump), across the wrap \(acrossWrap)")
    }
}
