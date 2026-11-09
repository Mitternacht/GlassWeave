import CoreGraphics
import Metal
import Testing
@testable import GlassWeave

/// The legibility rule: the worst-case contrast between text and the panel
/// interior over any background, the smallest tint strength that guarantees
/// a ratio, and the rendered panel actually keeping it.
struct GlassLegibilityTests {
    /// The laboratory's light and dark tint colors.
    static let lightTint = GlassTint(red: 0.97, green: 0.98, blue: 1.0, strength: 0.45)
    static let darkTint = GlassTint(red: 0.08, green: 0.09, blue: 0.12, strength: 0.45)

    @Test func `Luminance and contrast follow WCAG 2`() {
        #expect(GlassTint.relativeLuminance(red: 1, green: 1, blue: 1) == 1)
        #expect(GlassTint.relativeLuminance(red: 0, green: 0, blue: 0) == 0)
        #expect(abs(GlassTint.contrastRatio(0, 1) - 21) < 1e-12)
        #expect(GlassTint.contrastRatio(0.3, 0.3) == 1)
        // #767676 on white is the classic 4.5:1 gray (4.54:1).
        let gray = GlassTint.relativeLuminance(red: 118.0 / 255, green: 118.0 / 255, blue: 118.0 / 255)
        #expect(abs(GlassTint.contrastRatio(gray, 1) - 4.54) < 0.01)
    }

    @Test(arguments: [(GlassLegibilityTests.lightTint, 0.0), (GlassLegibilityTests.darkTint, 1.0), (GlassLegibilityTests.lightTint, 1.0), (GlassLegibilityTests.darkTint, 0.0)])
    func `The worst case is the lowest contrast over every background`(tint: GlassTint, text: Double) {
        let lt = tint.relativeLuminance
        var lowest = Double.infinity
        for step in 0...1000 {
            let background = Double(step) / 1000
            let interior = tint.strength * lt + (1 - tint.strength) * background
            lowest = min(lowest, GlassTint.contrastRatio(text, interior))
        }
        #expect(abs(tint.worstCaseContrast(againstTextLuminance: text) - lowest) < 1e-9)
    }

    @Test(arguments: [(GlassLegibilityTests.lightTint, 0.0, 4.5), (GlassLegibilityTests.darkTint, 1.0, 4.5), (GlassLegibilityTests.lightTint, 0.0, 7.0), (GlassLegibilityTests.darkTint, 1.0, 7.0)])
    func `The minimum strength reaches the ratio and nothing weaker does`(tint: GlassTint, text: Double, ratio: Double) throws {
        let minimum = try #require(tint.minimumStrength(forContrast: ratio, againstTextLuminance: text))
        var probe = tint
        probe.strength = minimum
        #expect(probe.worstCaseContrast(againstTextLuminance: text) >= ratio * (1 - 1e-9))
        probe.strength = max(minimum - 0.001, 0)
        #expect(probe.worstCaseContrast(againstTextLuminance: text) < ratio)
    }

    @Test func `The laboratory's tints need the expected strengths`() throws {
        // Black label text on the light tint: the 0.45 the lab uses is
        // already enough for 4.5:1 (and 7:1).
        let light = try #require(Self.lightTint.minimumStrength(forContrast: 4.5, againstTextLuminance: 0))
        #expect(light < 0.45)
        // White label text on the dark tint needs about 0.82 for 4.5:1 and
        // about 0.91 for 7:1, whatever the background.
        let dark = try #require(Self.darkTint.minimumStrength(forContrast: 4.5, againstTextLuminance: 1))
        #expect(dark > 0.81 && dark < 0.83)
        let darkHigh = try #require(Self.darkTint.minimumStrength(forContrast: 7, againstTextLuminance: 1))
        #expect(darkHigh > 0.90 && darkHigh < 0.92)
    }

    @Test func `No strength helps text the tint cannot contrast with`() {
        // Black text on a black tint, white text on a white tint.
        #expect(GlassTint(red: 0, green: 0, blue: 0, strength: 0).minimumStrength(forContrast: 4.5, againstTextLuminance: 0) == nil)
        #expect(GlassTint(red: 1, green: 1, blue: 1, strength: 0).minimumStrength(forContrast: 4.5, againstTextLuminance: 1) == nil)
        #expect(Self.lightTint.minimumStrength(forContrast: 1, againstTextLuminance: 0.5) == 0)
    }

    /// Renders the panel over a black and a white half and measures the
    /// interior on both: the extremes of any background.
    @Test(.timeLimit(.minutes(1)), arguments: [(GlassLegibilityTests.lightTint, 0.0, 4.5), (GlassLegibilityTests.darkTint, 1.0, 4.5), (GlassLegibilityTests.darkTint, 1.0, 7.0)])
    func `A rendered panel keeps the ratio over black and white`(tint: GlassTint, text: Double, ratio: Double) async throws {
        let gpu = try GPUContext()
        var chosen = tint
        let minimum = try #require(tint.minimumStrength(forContrast: ratio, againstTextLuminance: text))
        // Rounded up to whole percent, as the laboratory does.
        chosen.strength = max(tint.strength, (minimum * 100).rounded(.up) / 100)
        let width = 128, height = 64
        var bytes = [UInt8]()
        for _ in 0..<height {
            for x in 0..<width {
                let value: UInt8 = x < width / 2 ? 0 : 255
                bytes += [value, value, value, 255]
            }
        }
        let renderer = try GlassRenderer(commandQueue: gpu.queue)
        try renderer.setSource(gpu.makeLease(bgra: bytes, width: width, height: height))
        try renderer.setPanel(GlassPanel(
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            parameters: GlassParameters(cornerRadius: 12, bezelWidth: 10, refraction: 0.85, edgeHighlight: 0.6, tint: chosen)
        ))
        let target = try gpu.makeTarget(width: width, height: height)
        #expect(renderer.draw(targetPixelSize: (width, height), displayScale: 1) { target } == .submitted(frameID: 1))
        let image = try await gpu.readBack(try #require(target.renderPassDescriptor.colorAttachments[0].texture))
        // Interior pixels, clear of the 10-pixel rim, over each half.
        for x in [16, 40, 88, 112] {
            for y in [16, 32, 48] {
                let bgr = image.channels(x: x, y: y) / 255
                let luminance = GlassTint.relativeLuminance(red: bgr.z, green: bgr.y, blue: bgr.x)
                #expect(GlassTint.contrastRatio(luminance, text) >= ratio, "pixel (\(x), \(y)) luminance \(luminance)")
            }
        }
    }
}
