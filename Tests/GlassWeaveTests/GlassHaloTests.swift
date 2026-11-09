import CoreGraphics
import Foundation
import Metal
import Testing
@testable import GlassWeave
import GlassWeaveShaderTypes

/// GW-18's parameter boundary: the halo and pulse fields of `GlassGlow`,
/// their units, ranges, defaults, and normalization, the pulse level, and
/// the renderer's effect time.
struct GlassHaloParameterTests {
    private static let frame = CGRect(x: 0, y: 0, width: 120, height: 80)
    private static let red = [GlassGlow.ColorStop(red: 1, green: 0, blue: 0)]

    private func normalizedGlow(_ glow: GlassGlow) throws -> GlassGlow {
        try GlassPanel(frame: Self.frame, parameters: GlassParameters(glow: glow)).normalized().parameters.glow
    }

    @Test func `Halo and pulse default to none`() {
        let glow = GlassGlow(colors: Self.red)
        #expect(glow.haloRadius == 0)
        #expect(glow.haloIntensity == 0.5)
        #expect(glow.pulsePeriod == 2)
        #expect(glow.pulseDepth == 0)
        #expect(!glow.hasHalo)
        #expect(!glow.isAnimated)
        #expect(GlassGlow.maximumHaloRadius == 128)
        #expect(GlassGlow.minimumPulsePeriod == 0.5)
        #expect(GlassGlow.maximumPulsePeriod == 60)
        #expect(!GlassGlow.none.isAnimated && !GlassGlow.none.hasHalo)
    }

    @Test func `A halo alone makes a glow visible, and a pulse animates only what it can dim`() {
        let haloOnly = GlassGlow(colors: Self.red, rimIntensity: 0, innerGlowIntensity: 0, haloRadius: 10)
        #expect(haloOnly.isVisible && haloOnly.hasHalo)
        #expect(!GlassGlow(colors: Self.red, rimIntensity: 0, innerGlowIntensity: 0, haloRadius: 10, haloIntensity: 0).isVisible)
        #expect(!GlassGlow(colors: [], haloRadius: 10).hasHalo)
        #expect(GlassGlow(colors: Self.red, pulseDepth: 0.5).isAnimated)
        #expect(!GlassGlow(colors: Self.red, pulseDepth: 0).isAnimated)
        // The center fill does not pulse, so a glow that is only a center
        // fill never animates.
        #expect(!GlassGlow(colors: Self.red, rimIntensity: 0, innerGlowIntensity: 0, centerOpacity: 0.3, pulseDepth: 1).isAnimated)
        #expect(GlassGlow(colors: Self.red, rimIntensity: 0, innerGlowIntensity: 0, haloRadius: 8, pulseDepth: 1).isAnimated)
        #expect(!GlassGlow(colors: [], pulseDepth: 1).isAnimated)
    }

    @Test func `Halo and pulse values in range pass through, even a halo longer than the panel's half side`() throws {
        let glow = GlassGlow(colors: Self.red, haloRadius: 64, haloIntensity: 0.7, pulsePeriod: 1.6, pulseDepth: 0.45)
        #expect(try normalizedGlow(glow) == glow)
    }

    @Test func `Out-of-range halo and pulse values are clamped`() throws {
        let high = try normalizedGlow(GlassGlow(colors: Self.red, haloRadius: 500, haloIntensity: 1.5, pulsePeriod: 1000, pulseDepth: 7))
        #expect(high.haloRadius == GlassGlow.maximumHaloRadius)
        #expect(high.haloIntensity == 1)
        #expect(high.pulsePeriod == GlassGlow.maximumPulsePeriod)
        #expect(high.pulseDepth == 1)
        let low = try normalizedGlow(GlassGlow(colors: Self.red, haloRadius: -3, haloIntensity: -1, pulsePeriod: 0.1, pulseDepth: -0.2))
        #expect(low.haloRadius == 0)
        #expect(low.haloIntensity == 0)
        #expect(low.pulsePeriod == GlassGlow.minimumPulsePeriod)
        #expect(low.pulseDepth == 0)
        #expect(try normalizedGlow(GlassGlow(colors: Self.red, pulsePeriod: -5)).pulsePeriod == GlassGlow.minimumPulsePeriod)
    }

    @Test(arguments: [
        GlassParameterError.Field.glowHaloRadius, .glowHaloIntensity, .glowPulsePeriod, .glowPulseDepth,
    ])
    func `A non-finite halo or pulse value is rejected naming its field`(field: GlassParameterError.Field) {
        for value in [Double.nan, .infinity, -.infinity] {
            // Even without colors, like every other glow field.
            for colors in [Self.red, []] {
                var glow = GlassGlow(colors: colors)
                switch field {
                case .glowHaloRadius: glow.haloRadius = value
                case .glowHaloIntensity: glow.haloIntensity = value
                case .glowPulsePeriod: glow.pulsePeriod = value
                default: glow.pulseDepth = value
                }
                let panel = GlassPanel(frame: Self.frame, parameters: GlassParameters(glow: glow))
                #expect(throws: GlassParameterError.nonFinite(field)) {
                    try panel.normalized()
                }
            }
        }
    }

    @Test func `The renderer keeps a finite effect time and rejects a non-finite one`() throws {
        let renderer = try GlassRenderer(commandQueue: GPUContext().queue)
        #expect(renderer.effectTime == 0)
        try renderer.setEffectTime(-12.5)
        #expect(renderer.effectTime == -12.5)
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(throws: GlassParameterError.nonFinite(.effectTime)) {
                try renderer.setEffectTime(value)
            }
            #expect(renderer.effectTime == -12.5, "A rejected time leaves the last one")
        }
    }

    @Test func `The pulse level follows the documented cosine`() {
        let glow = GlassGlow(colors: Self.red, pulsePeriod: 1.6, pulseDepth: 0.6)
        let cases: [(time: Double, level: Double)] = [
            (0, 1), (0.4, 0.7), (0.8, 0.4), (1.2, 0.7), (1.6, 1), (-0.8, 0.4), (-0.4, 0.7),
            // A long-running clock keeps its accuracy.
            (1.6 * 1e7 + 0.8, 0.4),
        ]
        for (time, level) in cases {
            #expect(abs(glow.pulseLevel(at: time) - level) < 1e-9, "level at \(time) s")
        }
        // Over one period it stays within 1 − depth ... 1 and averages the
        // documented steady level, 1 − depth / 2.
        let samples = (0..<1600).map { glow.pulseLevel(at: Double($0) / 1000) }
        #expect(abs(samples.min()! - 0.4) < 1e-5)
        #expect(samples.max()! == 1)
        #expect(abs(samples.reduce(0, +) / Double(samples.count) - 0.7) < 1e-9)
        // No pulse is level 1 at any time; a non-finite time gives time 0.
        #expect(GlassGlow(colors: Self.red).pulseLevel(at: 0.8) == 1)
        #expect(glow.pulseLevel(at: .nan) == 1)
    }

    @Test func `A steady glow keeps the pulse's mean level and does not animate`() {
        let glow = GlassGlow(
            colors: Self.red, rimIntensity: 0.8, innerGlowIntensity: 0.5, centerOpacity: 0.2,
            haloRadius: 20, haloIntensity: 0.6, pulsePeriod: 2, pulseDepth: 0.5
        )
        let steady = glow.steadyAtMeanPulseLevel()
        #expect(steady.pulseDepth == 0)
        #expect(steady.rimIntensity == 0.8 * 0.75)
        #expect(steady.innerGlowIntensity == 0.5 * 0.75)
        #expect(steady.haloIntensity == 0.6 * 0.75)
        #expect(steady.centerOpacity == 0.2, "The center fill does not pulse")
        #expect(steady.haloRadius == 20 && steady.colors == glow.colors)
        #expect(!steady.isAnimated)
        let still = GlassGlow(colors: Self.red, haloRadius: 20)
        #expect(still.steadyAtMeanPulseLevel() == still)
    }

    @Test func `The geometry applies the pulse level and converts the halo to pixels`() throws {
        let glow = GlassGlow(
            colors: Self.red, rimIntensity: 0.8, innerGlowIntensity: 0.5, centerOpacity: 0.2,
            haloRadius: 20, haloIntensity: 0.6, pulsePeriod: 2, pulseDepth: 0.5
        )
        let panel = try GlassPanel(frame: Self.frame, parameters: GlassParameters(glow: glow)).normalized()
        // Half a period: level 1 − 0.5 = 0.5.
        let g = GlassPanelGeometry(panel: panel, displayScale: 3, effectTime: 1)
        let drawn = try #require(g.glow)
        #expect(abs(drawn.pulseLevel - 0.5) < 1e-12)
        #expect(drawn.haloRadius == 60)
        #expect(abs(drawn.haloIntensity - 0.3) < 1e-12)
        #expect(abs(drawn.rimIntensity - 0.4) < 1e-12)
        #expect(abs(drawn.innerIntensity - 0.25) < 1e-12)
        #expect(drawn.centerOpacity == 0.2)
        #expect(g.quadOutset == 61)
        let uniforms = g.uniforms(background: GWBackgroundUniformsForTests.zero, targetWidth: 10, targetHeight: 10)
        #expect(uniforms.glowHaloRadius == 60)
        #expect(uniforms.glowHaloIntensity == Float(drawn.haloIntensity))
        #expect(uniforms.padding4 == 0 && uniforms.padding5 == 0)
        // Without a halo the quad keeps its one-pixel outset and the record
        // says no halo.
        var noHalo = panel
        noHalo.parameters.glow.haloRadius = 0
        let plain = GlassPanelGeometry(panel: noHalo, displayScale: 3, effectTime: 1)
        #expect(plain.quadOutset == 1)
        #expect(plain.uniforms(background: GWBackgroundUniformsForTests.zero, targetWidth: 10, targetHeight: 10).glowHaloRadius == 0)
    }
}

@Suite(.timeLimit(.minutes(2)))
struct GlassHaloRenderTests {
    /// Renders the fixture 1:1 with a panel at an effect time and reads it
    /// back.
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

    /// A renderer whose panel pass is the frozen GW-17 shader
    /// (`Tests/GlassWeaveTests/Shaders/GlassBaselineGW17.metal`).
    private func gw17Renderer(_ gpu: GPUContext) throws -> GlassRenderer {
        try GlassRenderer(
            commandQueue: gpu.queue,
            library: BackgroundRenderer.makeLibrary(device: gpu.device),
            panelLibrary: gpu.device.makeDefaultLibrary(bundle: .module),
            panelVertex: "gw_gw17_glass_vertex", panelFragment: "gw_gw17_glass_fragment"
        )
    }

    private func geometry(_ panel: GlassPanel, scale: Double = 1, effectTime: Double = 0) throws -> GlassPanelGeometry {
        GlassPanelGeometry(panel: try panel.normalized(), displayScale: scale, effectTime: effectTime)
    }

    /// Largest per-channel difference between the image and the CPU model.
    private func maximumError(_ image: RenderedImage, _ reference: GlassReference) -> Double {
        var worst = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                worst = max(worst, image.channels(x: x, y: y).largestDifference(from: reference.encodedColor(x: x, y: y)))
            }
        }
        return worst
    }

    /// Bytes that differ between two images, counted so a failure reports a
    /// number instead of every byte.
    private func differingBytes(_ a: RenderedImage, _ b: RenderedImage) -> Int {
        zip(a.bgra, b.bgra).count { $0 != $1 }
    }

    /// A flat panel (no refraction, tint, or edge light) so the glow alone
    /// changes it.
    private static func flatPanel(_ frame: CGRect, cornerRadius: Double, glow: GlassGlow) -> GlassPanel {
        GlassPanel(frame: frame, parameters: GlassParameters(
            cornerRadius: cornerRadius, bezelWidth: 0, refraction: 0, edgeHighlight: 0, tint: .none, glow: glow
        ))
    }

    private static let darkBackground: (UInt8, UInt8, UInt8) = (30, 32, 36)

    /// Linear-light HSV hue in degrees of a blue, green, red triple.
    private static func hue(_ bgr: SIMD3<Double>) -> Double {
        let r = bgr.z, g = bgr.y, b = bgr.x
        let high = max(r, g, b), low = min(r, g, b)
        guard high > low else { return 0 }
        var h: Double
        if high == r {
            h = (g - b) / (high - low)
        } else if high == g {
            h = 2 + (b - r) / (high - low)
        } else {
            h = 4 + (r - g) / (high - low)
        }
        h *= 60
        return h < 0 ? h + 360 : h
    }

    private static func decoded(_ bytes: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(GlassPanelGeometry.decodeSRGB(bytes.x / 255), GlassPanelGeometry.decodeSRGB(bytes.y / 255), GlassPanelGeometry.decodeSRGB(bytes.z / 255))
    }

    // MARK: Without a halo, the GW-17 output is unchanged

    struct Gw17Case: CustomTestStringConvertible, Sendable {
        let name: String
        let parameters: GlassParameters
        let effectTime: Double
        var testDescription: String { name }
    }

    static let gw17Cases: [Gw17Case] = {
        let gradient = GlassGlow(
            colors: [
                .init(red: 1, green: 0.2, blue: 0.3, angle: 15), .init(red: 1, green: 0.85, blue: 0.2, angle: 100),
                .init(red: 0.2, green: 0.9, blue: 0.6, angle: 200), .init(red: 0.4, green: 0.3, blue: 1, angle: 290),
            ],
            rimWidth: 3, rimSoftness: 1, innerGlowRadius: 30, innerGlowIntensity: 0.4, lightAngle: 135, directionality: 1
        )
        let refracting = { (glow: GlassGlow) in
            GlassParameters(cornerRadius: 26, bezelWidth: 18, refraction: 0.8, edgeHighlight: 0.7,
                            tint: GlassTint(red: 0.2, green: 0.3, blue: 0.5, strength: 0.3), glow: glow)
        }
        var radiusOnly = gradient
        radiusOnly.haloIntensity = 0.9 // radius 0: no halo
        var intensityZero = gradient
        intensityZero.haloRadius = 40
        intensityZero.haloIntensity = 0
        var pulsing = gradient
        pulsing.pulseDepth = 0.6
        pulsing.pulsePeriod = 1.6
        let centerFill = GlassGlow(colors: [.init(red: 0.3, green: 0.6, blue: 1)], innerGlowRadius: 999,
                                   innerGlowIntensity: 0.9, centerOpacity: 0.3, lightAngle: 270, directionality: 0.4)
        return [
            Gw17Case(name: "gradient, directional, no halo fields set", parameters: refracting(gradient), effectTime: 0),
            Gw17Case(name: "halo intensity without a radius", parameters: refracting(radiusOnly), effectTime: 0),
            Gw17Case(name: "halo radius with zero intensity", parameters: refracting(intensityZero), effectTime: 0),
            Gw17Case(name: "pulse at a whole period (level 1)", parameters: refracting(pulsing), effectTime: 3.2),
            Gw17Case(name: "center fill and deep inner glow", parameters: refracting(centerFill), effectTime: 7),
        ]
    }()

    @Test(arguments: gw17Cases)
    func `Without a halo the output is byte-identical to the GW-17 shader`(testCase: Gw17Case) async throws {
        let gpu = try GPUContext()
        let fixtures = [
            Fixture.coordinateGradient(width: 200, height: 160),
            Fixture.checkerboard(width: 200, height: 160, cell: 7, (250, 220, 30), (10, 30, 90)),
        ]
        for fixture in fixtures {
            let panel = GlassPanel(frame: CGRect(x: 18.5, y: 14.25, width: 151, height: 120), parameters: testCase.parameters)
            let current = try await render(gpu, fixture, panel: panel, effectTime: testCase.effectTime)
            let baseline = try await render(gpu, fixture, panel: panel, renderer: gw17Renderer(gpu))
            let differing = differingBytes(current, baseline)
            #expect(differing == 0, "\(differing) bytes differ, at most by \(current.maximumDifference(from: baseline))")
            // Control: the frozen shader does draw the glow.
            var plain = panel
            plain.parameters.glow = .none
            let glowOff = try await render(gpu, fixture, panel: plain, renderer: gw17Renderer(gpu))
            #expect(baseline.maximumDifference(from: glowOff) > 20)
        }
    }

    // MARK: Color

    static let haloColors: [GlassGlow.ColorStop] = [
        .init(red: 1, green: 0, blue: 0),
        .init(red: 0, green: 1, blue: 0),
        .init(red: 0, green: 0, blue: 1),
        .init(red: 1, green: 0.55, blue: 0.1),
        .init(red: 0.6, green: 0.2, blue: 1),
        .init(red: 0.1, green: 0.9, blue: 0.8),
        .init(red: 1, green: 0.2, blue: 0.75),
    ]

    /// Over black, a halo pixel is the glow color scaled in linear light, so
    /// its linear-light hue is the color's hue at every distance, and a
    /// channel the color lacks stays exactly zero.
    @Test(arguments: haloColors)
    func `The halo shows the glow color's hue`(color: GlassGlow.ColorStop) async throws {
        let gpu = try GPUContext()
        let source = Fixture.uniform(width: 200, height: 150, (0, 0, 0))
        let glow = GlassGlow(colors: [color], rimWidth: 2, rimSoftness: 0, innerGlowIntensity: 0, haloRadius: 30, haloIntensity: 1)
        let panel = Self.flatPanel(CGRect(x: 50, y: 40, width: 100, height: 70), cornerRadius: 20, glow: glow)
        let image = try await render(gpu, source, panel: panel)
        let g = try geometry(panel)
        let colorBGR = SIMD3(color.blue, color.green, color.red)
        let expectedHue = Self.hue(Self.decoded(colorBGR * 255))
        var probed = 0, wrongHue = 0, nonzeroMissingChannel = 0
        for y in 0..<source.height {
            for x in 0..<source.width {
                let distance = g.signedDistance(at: SIMD2(Double(x) + 0.5, Double(y) + 0.5))
                guard distance >= 1, distance < 30 else { continue }
                let bytes = image.channels(x: x, y: y)
                for channel in 0..<3 where colorBGR[channel] == 0 && bytes[channel] != 0 {
                    nonzeroMissingChannel += 1
                }
                let linear = Self.decoded(bytes)
                guard linear.max() >= 0.02 else { continue }
                probed += 1
                let difference = abs(Self.hue(linear) - expectedHue)
                if min(difference, 360 - difference) > 2 { wrongHue += 1 }
            }
        }
        #expect(probed > 2000)
        #expect(wrongHue == 0)
        #expect(nonzeroMissingChannel == 0)
    }

    // MARK: Falloff and extent

    /// Probes along rays leaving the outline: from the middle of each side
    /// and diagonally from each rounded corner.
    private static func rays(_ g: GlassPanelGeometry, cornerRadius: Double) -> [(origin: SIMD2<Double>, direction: SIMD2<Double>)] {
        let c = g.center, h = g.halfSize
        let diagonal = 1 / 2.0.squareRoot()
        var rays: [(SIMD2<Double>, SIMD2<Double>)] = [
            (SIMD2(c.x + h.x, c.y), SIMD2(1, 0)), (SIMD2(c.x - h.x, c.y), SIMD2(-1, 0)),
            (SIMD2(c.x, c.y + h.y), SIMD2(0, 1)), (SIMD2(c.x, c.y - h.y), SIMD2(0, -1)),
        ]
        for (sx, sy) in [(1.0, 1.0), (1, -1), (-1, 1), (-1, -1)] {
            let corner = SIMD2(c.x + sx * (h.x - cornerRadius), c.y + sy * (h.y - cornerRadius))
            let direction = SIMD2(sx * diagonal, sy * diagonal)
            rays.append((corner + direction * cornerRadius, direction))
        }
        return rays
    }

    @Test func `The halo falls off monotonically and is exactly zero from its radius on`() async throws {
        let gpu = try GPUContext()
        let source = Fixture.uniform(width: 241, height: 201, Self.darkBackground)
        let glow = GlassGlow(colors: [.init(red: 1, green: 0.6, blue: 0.2)], rimWidth: 2, rimSoftness: 1,
                             innerGlowIntensity: 0, haloRadius: 30, haloIntensity: 0.8)
        let panel = Self.flatPanel(CGRect(x: 60, y: 60, width: 121, height: 81), cornerRadius: 20, glow: glow)
        var noHaloGlow = glow
        noHaloGlow.haloRadius = 0
        let image = try await render(gpu, source, panel: panel)
        let noHalo = try await render(gpu, source, panel: Self.flatPanel(panel.frame, cornerRadius: 20, glow: noHaloGlow))
        let g = try geometry(panel)
        #expect(maximumError(image, GlassReference(source: source, geometry: g)) <= 1)

        // Along every ray the brightness never rises (one step of dither
        // allowed) and is exactly the background from the radius on.
        for (origin, direction) in Self.rays(g, cornerRadius: 20) {
            var previous = Double.infinity
            var risen = 0
            for step in 1...40 {
                let point = origin + direction * Double(step)
                let x = Int(point.x), y = Int(point.y)
                let distance = g.signedDistance(at: SIMD2(Double(x) + 0.5, Double(y) + 0.5))
                guard distance > 0.5 else { continue }
                let sum = image.channels(x: x, y: y).sum()
                if sum > previous + 3 { risen += 1 }
                previous = sum
                if distance >= 30 {
                    #expect(image.channels(x: x, y: y) == noHalo.channels(x: x, y: y), "ray \(direction) at \(distance) px")
                }
            }
            #expect(risen == 0, "ray from \(origin) along \(direction)")
        }

        // Every pixel at or beyond the radius keeps the glow-off bytes; inside
        // it the halo shows.
        var beyondChanged = 0, insideChanged = 0
        for y in 0..<source.height {
            for x in 0..<source.width {
                let distance = g.signedDistance(at: SIMD2(Double(x) + 0.5, Double(y) + 0.5))
                let changed = image.channels(x: x, y: y) != noHalo.channels(x: x, y: y)
                if distance >= 30, changed { beyondChanged += 1 }
                if distance > 1, distance < 20, image.channels(x: x, y: y).sum() > noHalo.channels(x: x, y: y).sum() + 20 { insideChanged += 1 }
            }
        }
        #expect(beyondChanged == 0)
        #expect(insideChanged > 3000)
    }

    @Test func `Pixels beyond the halo keep the background pass's bytes over any background`() async throws {
        let gpu = try GPUContext()
        let source = Fixture.coordinateGradient(width: 230, height: 190)
        let glow = GlassGlow(
            colors: [.init(red: 0.2, green: 0.9, blue: 1, angle: 0), .init(red: 0.7, green: 0.3, blue: 1, angle: 180)],
            rimWidth: 2, rimSoftness: 2, innerGlowRadius: 18, innerGlowIntensity: 0.6,
            lightAngle: 30, directionality: 0.8, haloRadius: 26, haloIntensity: 0.9
        )
        let panel = GlassPanel(frame: CGRect(x: 55.5, y: 48.25, width: 120, height: 92), parameters: GlassParameters(
            cornerRadius: 24, bezelWidth: 16, refraction: 0.7, edgeHighlight: 0.5,
            tint: GlassTint(red: 0.9, green: 0.95, blue: 1, strength: 0.3), glow: glow
        ))
        let image = try await render(gpu, source, panel: panel)
        let backgroundOnly = try await render(gpu, source, panel: nil)
        let g = try geometry(panel)
        var beyond = 0, changedBeyond = 0
        for y in 0..<source.height {
            for x in 0..<source.width where g.signedDistance(at: SIMD2(Double(x) + 0.5, Double(y) + 0.5)) >= 26 {
                beyond += 1
                if image.channels(x: x, y: y) != backgroundOnly.channels(x: x, y: y) { changedBeyond += 1 }
            }
        }
        #expect(beyond > 10_000)
        #expect(changedBeyond == 0)
    }

    // MARK: Blending

    /// The halo adds light: over a dark background no channel of any pixel
    /// drops below the background (beyond one step of dither on a single
    /// pixel, and not at all on average over the 4 × 4 dither cell), whatever
    /// the glow color, and across the outline the antialiased band never dips
    /// below both of its neighbours, so rim and halo meet without a dark seam.
    @Test func `The halo never darkens the background and leaves no dark seam at the outline`() async throws {
        let gpu = try GPUContext()
        let source = Fixture.uniform(width: 241, height: 201, Self.darkBackground)
        let background = SIMD3<Double>(36, 32, 30)
        for color in Self.haloColors {
            let glow = GlassGlow(colors: [color], rimWidth: 1.5, rimSoftness: 1.5, innerGlowRadius: 16,
                                 innerGlowIntensity: 0.6, lightAngle: 0, directionality: 0.5, haloRadius: 32, haloIntensity: 0.7)
            let panel = Self.flatPanel(CGRect(x: 60.3, y: 60.6, width: 120, height: 80), cornerRadius: 22, glow: glow)
            let image = try await render(gpu, source, panel: panel)
            let g = try geometry(panel)
            var darkerPixels = 0, darkerBlocks = 0, blocks = 0, haloPixels = 0
            for y in stride(from: 0, to: 200, by: 4) {
                for x in stride(from: 0, to: 240, by: 4) {
                    var blockSum = SIMD3<Double>.zero
                    var outside = true
                    for dy in 0..<4 {
                        for dx in 0..<4 {
                            let c = image.channels(x: x + dx, y: y + dy)
                            blockSum += c
                            // Inside the outline the rim tints the glass
                            // (source-over), which is not the halo.
                            guard g.coverage(at: SIMD2(Double(x + dx) + 0.5, Double(y + dy) + 0.5)) == 0 else {
                                outside = false
                                continue
                            }
                            haloPixels += 1
                            if (0..<3).contains(where: { c[$0] < background[$0] - 1 }) { darkerPixels += 1 }
                        }
                    }
                    guard outside else { continue }
                    blocks += 1
                    if (0..<3).contains(where: { blockSum[$0] / 16 < background[$0] - 0.25 }) { darkerBlocks += 1 }
                }
            }
            #expect(blocks > 1500 && haloPixels > 30_000)
            #expect(darkerPixels == 0, "color \(color)")
            #expect(darkerBlocks == 0, "color \(color)")
            // Across the outline on each ray: rim, antialiased band, halo.
            for (origin, direction) in Self.rays(g, cornerRadius: 22) {
                var sums: [Double] = []
                for step in -3...3 {
                    let point = origin + direction * Double(step)
                    sums.append(image.channels(x: Int(point.x), y: Int(point.y)).sum())
                }
                for index in 1..<(sums.count - 1) {
                    #expect(sums[index] >= min(sums[index - 1], sums[index + 1]) - 3, "dip at the outline for \(color) along \(direction): \(sums)")
                }
            }
        }
    }

    /// Over a background with bright and dark regions, every halo pixel is
    /// at least the background and at most the background screened with the
    /// full glow color, channel by channel: light is only added, and never
    /// more than the glow color itself.
    @Test func `Every halo pixel adds light, at most the full glow color`() async throws {
        let gpu = try GPUContext()
        let source = Fixture.checkerboard(width: 220, height: 180, cell: 5, (250, 240, 235), (12, 40, 70))
        let glow = GlassGlow(
            colors: [.init(red: 1, green: 0.3, blue: 0.1, angle: 0), .init(red: 0.2, green: 0.5, blue: 1, angle: 180)],
            rimWidth: 2, rimSoftness: 1, innerGlowIntensity: 0, haloRadius: 34, haloIntensity: 1
        )
        let panel = Self.flatPanel(CGRect(x: 50, y: 45, width: 120, height: 90), cornerRadius: 30, glow: glow)
        let image = try await render(gpu, source, panel: panel)
        let backgroundOnly = try await render(gpu, source, panel: nil)
        let g = try geometry(panel)
        var probed = 0, outsideRange = 0, brightened = 0
        for y in 0..<source.height {
            for x in 0..<source.width {
                let pixel = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                guard g.coverage(at: pixel) == 0, g.haloAlpha(at: pixel) > 0 else { continue }
                probed += 1
                let rgb = g.glowColor(atTurn: g.glowTurn(at: pixel))
                let color = SIMD3(rgb.z, rgb.y, rgb.x)
                let bg = backgroundOnly.channels(x: x, y: y)
                let bgLinear = Self.decoded(bg)
                let full = bgLinear + color * (SIMD3(repeating: 1) - bgLinear)
                let ceiling = SIMD3(GlassPanelGeometry.encodeSRGB(full.x), GlassPanelGeometry.encodeSRGB(full.y), GlassPanelGeometry.encodeSRGB(full.z)) * 255
                let c = image.channels(x: x, y: y)
                for channel in 0..<3 {
                    if c[channel] < bg[channel] - 1 || c[channel] > ceiling[channel] + 1 { outsideRange += 1 }
                }
                if c.sum() > bg.sum() + 6 { brightened += 1 }
            }
        }
        #expect(probed > 10_000)
        #expect(outsideRange == 0)
        #expect(brightened > 5_000)
    }

    @Test func `The halo is lit like the rim`() async throws {
        let gpu = try GPUContext()
        let source = Fixture.uniform(width: 201, height: 161, Self.darkBackground)
        // Light from the top, fully directional: the top halo is brightest,
        // the bottom one is not drawn at all.
        let glow = GlassGlow(colors: [.init(red: 1, green: 0.75, blue: 0.3)], rimWidth: 2, rimSoftness: 1,
                             innerGlowIntensity: 0, lightAngle: 0, directionality: 1, haloRadius: 24, haloIntensity: 1)
        let panel = Self.flatPanel(CGRect(x: 40, y: 40, width: 121, height: 81), cornerRadius: 16, glow: glow)
        let image = try await render(gpu, source, panel: panel)
        let backgroundOnly = try await render(gpu, source, panel: nil)
        let top = image.channels(x: 100, y: 34).sum()
        let side = image.channels(x: 166, y: 80).sum()
        let bottom = image.channels(x: 100, y: 127)
        #expect(top > side + 30)
        #expect(side > backgroundOnly.channels(x: 166, y: 80).sum() + 10)
        #expect(bottom == backgroundOnly.channels(x: 100, y: 127), "The side facing away gets no halo")
        #expect(maximumError(image, GlassReference(source: source, geometry: try geometry(panel))) <= 1)
    }

    // MARK: The CPU model

    static let modelCases: [GlassParameters] = [
        // A four-stop gradient, refracting tinted glass, directional light.
        GlassParameters(
            cornerRadius: 20, bezelWidth: 18, refraction: 0.8, edgeHighlight: 0.7,
            tint: GlassTint(red: 0.2, green: 0.3, blue: 0.5, strength: 0.3),
            glow: GlassGlow(colors: [
                .init(red: 1, green: 0.2, blue: 0.3, angle: 15), .init(red: 1, green: 0.85, blue: 0.2, angle: 100),
                .init(red: 0.2, green: 0.9, blue: 0.6, angle: 200), .init(red: 0.4, green: 0.3, blue: 1, angle: 290),
            ], rimWidth: 3, rimSoftness: 1, innerGlowRadius: 24, innerGlowIntensity: 0.4, lightAngle: 135,
            directionality: 0.7, haloRadius: 22, haloIntensity: 0.8)
        ),
        // A circle with a center fill and an even halo.
        GlassParameters(
            cornerRadius: 999, bezelWidth: 10, refraction: 0.5, edgeHighlight: 0,
            glow: GlassGlow(colors: [.init(red: 0.3, green: 0.6, blue: 1, angle: 0), .init(red: 1, green: 0.3, blue: 0.8, angle: 180)],
                            rimWidth: 1.5, rimSoftness: 1.5, innerGlowRadius: 999, innerGlowIntensity: 0.9,
                            centerOpacity: 0.3, lightAngle: 270, directionality: 0.4, haloRadius: 18, haloIntensity: 0.6)
        ),
        // A halo alone: no rim, inner glow, or center fill.
        GlassParameters(
            cornerRadius: 12, bezelWidth: 0, refraction: 0, edgeHighlight: 0,
            glow: GlassGlow(colors: [.init(red: 0.9, green: 0.1, blue: 0.2)], rimIntensity: 0, innerGlowIntensity: 0,
                            haloRadius: 28, haloIntensity: 1)
        ),
        // A sharp corner: the halo turns radially around it.
        GlassParameters(
            cornerRadius: 0, bezelWidth: 8, refraction: 0.3, edgeHighlight: 0.4,
            glow: GlassGlow(colors: [.init(red: 0.1, green: 1, blue: 0.5)], rimWidth: 1, rimSoftness: 1,
                            innerGlowRadius: 10, innerGlowIntensity: 0.5, haloRadius: 20, haloIntensity: 0.9)
        ),
    ]

    @Test(arguments: modelCases)
    func `The halo matches the CPU model`(parameters: GlassParameters) async throws {
        let gpu = try GPUContext()
        let source = Fixture.coordinateGradient(width: 230, height: 200)
        let frame = parameters.cornerRadius > 100
            ? CGRect(x: 45, y: 30, width: 141, height: 141)
            : CGRect(x: 40.5, y: 44.25, width: 150, height: 112)
        let panel = GlassPanel(frame: frame, parameters: parameters)
        let image = try await render(gpu, source, panel: panel)
        let g = try geometry(panel)
        #expect(g.glow?.haloRadius ?? 0 > 0)
        #expect(maximumError(image, GlassReference(source: source, geometry: g)) <= 1)
        // The CPU model itself stays finite everywhere.
        let reference = GlassReference(source: source, geometry: g)
        var nonFinite = 0
        for y in stride(from: 0, to: source.height, by: 3) {
            for x in stride(from: 0, to: source.width, by: 3) {
                let c = reference.linearColor(x: x, y: y)
                if !(c.x.isFinite && c.y.isFinite && c.z.isFinite) { nonFinite += 1 }
            }
        }
        #expect(nonFinite == 0)
    }

    /// The surface owns its whole target, so a halo reaching past it is cut
    /// at its edge and nowhere else: the pixels up to the edge show the halo,
    /// every pixel is written, and the image still matches the model.
    @Test func `A halo near the surface's edge is cut off only by the surface`() async throws {
        let gpu = try GPUContext()
        let source = Fixture.uniform(width: 180, height: 140, Self.darkBackground)
        let glow = GlassGlow(colors: [.init(red: 0.3, green: 0.8, blue: 1)], rimWidth: 2, rimSoftness: 1,
                             innerGlowIntensity: 0.3, haloRadius: 40, haloIntensity: 1)
        // 6 points from the left and top edges, so 34 points of halo fall
        // outside the surface there.
        let panel = Self.flatPanel(CGRect(x: 6, y: 6, width: 100, height: 70), cornerRadius: 18, glow: glow)
        let image = try await render(gpu, source, panel: panel)
        let backgroundOnly = try await render(gpu, source, panel: nil)
        #expect(maximumError(image, GlassReference(source: source, geometry: try geometry(panel))) <= 1)
        // The halo reaches the target's left and top edges beside the panel.
        #expect(image.channels(x: 0, y: 40).sum() > backgroundOnly.channels(x: 0, y: 40).sum() + 40)
        #expect(image.channels(x: 50, y: 0).sum() > backgroundOnly.channels(x: 50, y: 0).sum() + 40)
    }

    @Test func `A halo in points renders the same at every display scale`() async throws {
        let gpu = try GPUContext()
        let source = Fixture.coordinateGradient(width: 220, height: 180)
        let glow = GlassGlow(colors: [.init(red: 1, green: 0.3, blue: 0.6)], rimWidth: 4, rimSoftness: 2,
                             innerGlowRadius: 24, innerGlowIntensity: 0.6, lightAngle: 40, directionality: 0.5,
                             haloRadius: 24, haloIntensity: 0.8)
        let atScale1 = try await render(gpu, source, panel: Self.flatPanel(CGRect(x: 40, y: 34, width: 140, height: 112), cornerRadius: 32, glow: glow))
        var half = glow
        half.rimWidth = 2
        half.rimSoftness = 1
        half.innerGlowRadius = 12
        half.haloRadius = 12
        let atScale2 = try await render(
            gpu, source, panel: Self.flatPanel(CGRect(x: 20, y: 17, width: 70, height: 56), cornerRadius: 16, glow: half),
            displayScale: 2
        )
        #expect(atScale2.maximumDifference(from: atScale1) <= 1)
    }

    // MARK: Pulse

    private static let pulsing = GlassGlow(
        colors: [.init(red: 0.25, green: 0.85, blue: 1, angle: 0), .init(red: 0.65, green: 0.35, blue: 1, angle: 180)],
        rimWidth: 2, rimSoftness: 1.5, innerGlowRadius: 18, innerGlowIntensity: 0.7,
        lightAngle: 0, directionality: 0.3, haloRadius: 24, haloIntensity: 0.9, pulsePeriod: 1.6, pulseDepth: 0.6
    )

    @Test func `The pulse sets the glow's level at chosen instants`() async throws {
        let gpu = try GPUContext()
        let source = Fixture.uniform(width: 201, height: 161, Self.darkBackground)
        let panel = Self.flatPanel(CGRect(x: 40, y: 40, width: 121, height: 81), cornerRadius: 20, glow: Self.pulsing)
        var images: [Double: RenderedImage] = [:]
        for time in [0, 0.4, 0.8, 1.2, 1.6, -0.8, 1600.8] {
            let image = try await render(gpu, source, panel: panel, effectTime: time)
            let g = try geometry(panel, effectTime: time)
            #expect(maximumError(image, GlassReference(source: source, geometry: g)) <= 1, "time \(time)")
            images[time] = image
        }
        // Whole periods and mirrored instants give the same level, so the
        // same bytes.
        #expect(differingBytes(images[0]!, images[1.6]!) == 0)
        #expect(differingBytes(images[0.8]!, images[-0.8]!) == 0)
        #expect(differingBytes(images[0.4]!, images[1.2]!) == 0)
        #expect(images[1600.8]!.maximumDifference(from: images[0.8]!) <= 1)
        // Rim (top, one pixel in) and halo (top, six pixels out) dim from the
        // peak to the trough.
        for (x, y) in [(100, 40), (100, 33)] {
            let peak = images[0]!.channels(x: x, y: y).sum()
            let quarter = images[0.4]!.channels(x: x, y: y).sum()
            let trough = images[0.8]!.channels(x: x, y: y).sum()
            #expect(peak > quarter + 6 && quarter > trough + 6, "at (\(x), \(y)): \(peak), \(quarter), \(trough)")
        }
        // At the trough the glow is the same glow with its rim, inner glow,
        // and halo at 1 − depth, and no pulse.
        var dimmed = Self.pulsing
        dimmed.pulseDepth = 0
        dimmed.rimIntensity *= 0.4
        dimmed.innerGlowIntensity *= 0.4
        dimmed.haloIntensity *= 0.4
        let still = try await render(gpu, source, panel: Self.flatPanel(panel.frame, cornerRadius: 20, glow: dimmed), effectTime: 123)
        #expect(still.maximumDifference(from: images[0.8]!) <= 1)
        // The middle stays exactly the glass without a glow at every instant.
        let glowOff = try await render(gpu, source, panel: Self.flatPanel(panel.frame, cornerRadius: 20, glow: .none))
        let g = try geometry(panel)
        for image in images.values {
            var changedMiddle = 0
            for y in 0..<source.height {
                for x in 0..<source.width where g.signedDistance(at: SIMD2(Double(x) + 0.5, Double(y) + 0.5)) < -19 {
                    if image.channels(x: x, y: y) != glowOff.channels(x: x, y: y) { changedMiddle += 1 }
                }
            }
            #expect(changedMiddle == 0)
        }
    }

    @Test func `The same effect time renders the same bytes, and other times differ`() async throws {
        let gpu = try GPUContext()
        let source = Fixture.checkerboard(width: 160, height: 120, cell: 6, (250, 220, 30), (10, 30, 90))
        let panel = GlassPanel(frame: CGRect(x: 30.5, y: 26.25, width: 99, height: 67), parameters: GlassParameters(glow: Self.pulsing))
        let first = try await render(gpu, source, panel: panel, effectTime: 0.37)
        let second = try await render(gpu, source, panel: panel, effectTime: 0.37)
        let later = try await render(gpu, source, panel: panel, effectTime: 0.53)
        #expect(differingBytes(first, second) == 0)
        #expect(differingBytes(first, later) > 1000)
    }
}

/// A zero background record for building panel uniforms in CPU tests.
enum GWBackgroundUniformsForTests {
    static let zero = GWBackgroundUniforms(
        uvFromDestinationX: .zero, uvFromDestinationY: .zero, uvOrigin: .zero, sampleClampMin: .zero, sampleClampMax: .zero
    )
}
