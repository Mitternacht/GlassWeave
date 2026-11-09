import Foundation
@testable import GlassWeave

/// Small deterministic source images for glass tests, as tightly packed
/// sRGB-encoded BGRA bytes, rows top to bottom.
struct Fixture {
    let width: Int
    let height: Int
    let bgra: [UInt8]

    private init(width: Int, height: Int, color: (Int, Int) -> (red: UInt8, green: UInt8, blue: UInt8)) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = color(x, y)
                bytes += [c.blue, c.green, c.red, 255]
            }
        }
        self.width = width
        self.height = height
        self.bgra = bytes
    }

    /// Red holds the column and green the row (both 0...255), blue is 64.
    /// Neighboring texels differ by one step, so a sample's value locates
    /// it to a fraction of a texel.
    static func coordinateGradient(width: Int = 256, height: Int = 256) -> Fixture {
        precondition(width <= 256 && height <= 256)
        return Fixture(width: width, height: height) { x, y in (UInt8(x), UInt8(y), 64) }
    }

    /// Square cells alternating between two colors.
    static func checkerboard(
        width: Int, height: Int, cell: Int,
        _ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8)
    ) -> Fixture {
        Fixture(width: width, height: height) { x, y in ((x / cell + y / cell) % 2 == 0) ? a : b }
    }

    /// Dark and bright gray quadrants, so the image has both a vertical and
    /// a horizontal hard edge through its center.
    static func brightDarkQuadrants(width: Int, height: Int, dark: UInt8, bright: UInt8) -> Fixture {
        Fixture(width: width, height: height) { x, y in
            let value = (x < width / 2) == (y < height / 2) ? dark : bright
            return (value, value, value)
        }
    }

    /// One color everywhere.
    static func uniform(width: Int, height: Int, _ color: (UInt8, UInt8, UInt8)) -> Fixture {
        Fixture(width: width, height: height) { _, _ in color }
    }

    /// One color inside `rect` and another outside it.
    static func framed(width: Int, height: Int, rect: PixelRect, inside: (UInt8, UInt8, UInt8), outside: (UInt8, UInt8, UInt8)) -> Fixture {
        Fixture(width: width, height: height) { x, y in
            x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height ? inside : outside
        }
    }

    /// The sRGB-encoded channel values (blue, green, red) at a texel.
    func texel(_ x: Int, _ y: Int) -> SIMD3<Double> {
        let index = (y * width + x) * 4
        return SIMD3(Double(bgra[index]), Double(bgra[index + 1]), Double(bgra[index + 2])) / 255
    }
}

/// A CPU model of the glass pass for a source presented 1:1 (source and
/// target the same size, whole texture valid, upright), where a target pixel
/// position is also the source position in texels.
///
/// It mirrors `Glass.metal` with `GlassPanelGeometry` and bilinear filtering
/// in linear light, and predicts every output byte.
struct GlassReference {
    let source: Fixture
    let geometry: GlassPanelGeometry?

    /// Bilinear sample in linear light, clamped half a texel inside the
    /// texture, at a position in texels. Returns blue, green, red.
    func sample(_ position: SIMD2<Double>) -> SIMD3<Double> {
        let x = min(max(position.x, 0.5), Double(source.width) - 0.5) - 0.5
        let y = min(max(position.y, 0.5), Double(source.height) - 0.5) - 0.5
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let x1 = min(x0 + 1, source.width - 1), y1 = min(y0 + 1, source.height - 1)
        let fx = x - Double(x0), fy = y - Double(y0)
        func linear(_ tx: Int, _ ty: Int) -> SIMD3<Double> {
            let t = source.texel(tx, ty)
            return SIMD3(GlassPanelGeometry.decodeSRGB(t.x), GlassPanelGeometry.decodeSRGB(t.y), GlassPanelGeometry.decodeSRGB(t.z))
        }
        let top = linear(x0, y0) * (1 - fx) + linear(x1, y0) * fx
        let bottom = linear(x0, y1) * (1 - fx) + linear(x1, y1) * fx
        return top * (1 - fy) + bottom * fy
    }

    /// The halo's opacity at a pixel, where the shader evaluates it: only
    /// where the panel's coverage is below 1.
    func haloAlpha(at pixel: SIMD2<Double>) -> Double {
        guard let geometry, !geometry.isEmpty, geometry.coverage(at: pixel) < 1 else { return 0 }
        return geometry.haloAlpha(at: pixel)
    }

    /// The glow color at a pixel's angle, in blue, green, red order.
    private func glowColorBGR(at pixel: SIMD2<Double>) -> SIMD3<Double> {
        guard let geometry else { return .zero }
        let rgb = geometry.glowColor(atTurn: geometry.glowTurn(at: pixel))
        return SIMD3(rgb.z, rgb.y, rgb.x)
    }

    /// The predicted output pixel in linear light (blue, green, red).
    func linearColor(x: Int, y: Int) -> SIMD3<Double> {
        let pixel = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
        let background = sample(pixel)
        guard let geometry, !geometry.isEmpty else { return background }
        let coverage = geometry.coverage(at: pixel)
        // The part of the pixel outside the outline: the background with the
        // halo's premultiplied light screened over it.
        var outside = background
        let halo = haloAlpha(at: pixel)
        if halo > 0 {
            outside = background + glowColorBGR(at: pixel) * halo * (SIMD3(repeating: 1) - background)
        }
        guard coverage > 0 else { return outside }
        var glass = sample(geometry.samplePosition(at: pixel))
        let tint = SIMD3(geometry.tintLinear.z, geometry.tintLinear.y, geometry.tintLinear.x)
        glass = glass * (1 - geometry.tintStrength) + tint * geometry.tintStrength
        let highlight = geometry.highlight(at: pixel)
        glass = glass + (SIMD3(repeating: 1) - glass) * highlight
        let glowAlpha = geometry.glowAlpha(at: pixel)
        if glowAlpha > 0 {
            glass = glass + (glowColorBGR(at: pixel) - glass) * glowAlpha
        }
        return outside * (1 - coverage) + glass * coverage
    }

    /// Whether the glow or its halo draws at a pixel, so the shader dithers
    /// it.
    func isDithered(x: Int, y: Int) -> Bool {
        let pixel = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
        guard let geometry, !geometry.isEmpty else { return false }
        if haloAlpha(at: pixel) > 0 { return true }
        return geometry.coverage(at: pixel) > 0 && geometry.glowAlpha(at: pixel) > 0
    }

    /// The predicted output bytes (blue, green, red) on the 0...255 scale,
    /// before rounding, including the glow's ordered dither.
    func encodedColor(x: Int, y: Int) -> SIMD3<Double> {
        let c = linearColor(x: x, y: y)
        let encoded = SIMD3(
            GlassPanelGeometry.encodeSRGB(c.x), GlassPanelGeometry.encodeSRGB(c.y), GlassPanelGeometry.encodeSRGB(c.z)
        ) * 255
        guard isDithered(x: x, y: y) else { return encoded }
        let dithered = encoded + SIMD3(repeating: GlassPanelGeometry.ditherOffset(column: x, row: y))
        return dithered.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 255))
    }
}

extension RenderedImage {
    /// Blue, green, red of a pixel on the 0...255 scale.
    func channels(x: Int, y: Int) -> SIMD3<Double> {
        let index = (y * width + x) * 4
        return SIMD3(Double(bgra[index]), Double(bgra[index + 1]), Double(bgra[index + 2]))
    }

    /// The largest per-channel difference from `other` over all pixels.
    func maximumDifference(from other: RenderedImage) -> Int {
        precondition(width == other.width && height == other.height)
        return zip(bgra, other.bgra).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }
}

extension SIMD3 where Scalar == Double {
    /// The largest absolute difference between corresponding channels.
    func largestDifference(from other: SIMD3<Double>) -> Double {
        let d = self - other
        return Swift.max(Swift.abs(d.x), Swift.abs(d.y), Swift.abs(d.z))
    }
}
