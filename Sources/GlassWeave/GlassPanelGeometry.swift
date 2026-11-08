import Foundation
internal import GlassWeaveShaderTypes

/// One normalized panel converted to target pixels, plus the optical model
/// that `Glass.metal` evaluates per pixel.
///
/// The renderer builds the uploaded record from this type, and tests use its
/// functions as the CPU reference for the shader. Positions are in target
/// pixels (origin top-left, y down); a pixel's center is at
/// `(column + 0.5, row + 0.5)`.
struct GlassPanelGeometry: Equatable {
    var center: SIMD2<Double>
    var halfSize: SIMD2<Double>
    var cornerRadius: Double
    var bezelWidth: Double
    /// Corner radius of the field that orients rim normals:
    /// `max(cornerRadius, bezelWidth)`. With it, normals turn smoothly
    /// around corners even when the rim is wider than the corner radius.
    var normalRadius: Double
    /// Displacement at the outline, in pixels: `refraction × bezelWidth / 2`.
    var maxDisplacement: Double
    /// Peak edge illumination as a fraction of the way to white.
    var edgeHighlight: Double
    /// Tint in linear light.
    var tintLinear: SIMD3<Double>
    var tintStrength: Double

    /// Light direction for edge illumination (from the upper left, y down).
    static let lightDirection = SIMD2<Double>(-1, -1) / 2.0.squareRoot()

    /// - Parameters:
    ///   - panel: A panel that has passed ``GlassPanel/normalized()``.
    ///   - displayScale: Pixels per point, finite and positive.
    init(panel: GlassPanel, displayScale: Double) {
        precondition(displayScale.isFinite && displayScale > 0, "The display scale must be finite and positive")
        let frame = panel.frame
        let parameters = panel.parameters
        center = SIMD2(Double(frame.midX), Double(frame.midY)) * displayScale
        halfSize = SIMD2(Double(frame.width), Double(frame.height)) * (displayScale / 2)
        cornerRadius = parameters.cornerRadius * displayScale
        bezelWidth = parameters.bezelWidth * displayScale
        normalRadius = max(cornerRadius, bezelWidth)
        maxDisplacement = parameters.refraction * bezelWidth / 2
        edgeHighlight = parameters.edgeHighlight * GlassParameters.maximumEdgeHighlight
        tintLinear = SIMD3(
            Self.decodeSRGB(parameters.tint.red),
            Self.decodeSRGB(parameters.tint.green),
            Self.decodeSRGB(parameters.tint.blue)
        )
        tintStrength = parameters.tint.strength
    }

    /// A panel without area draws nothing.
    var isEmpty: Bool {
        halfSize.x <= 0 || halfSize.y <= 0
    }

    // MARK: Shape field

    /// Signed distance to the outline in pixels: negative inside, positive
    /// outside.
    func signedDistance(at pixel: SIMD2<Double>) -> Double {
        let q = pixel - center
        let d = abs(q) - (halfSize - cornerRadius)
        let outside = SIMD2(max(d.x, 0), max(d.y, 0))
        return (outside.x * outside.x + outside.y * outside.y).squareRoot()
            + min(max(d.x, d.y), 0) - cornerRadius
    }

    /// The outward unit normal that orients refraction and illumination.
    func outwardNormal(at pixel: SIMD2<Double>) -> SIMD2<Double> {
        let q = pixel - center
        let d = abs(q) - (halfSize - normalRadius)
        if d.x > 0, d.y > 0 {
            let length = (d.x * d.x + d.y * d.y).squareRoot()
            return SIMD2(d.x / length * Self.sign(q.x), d.y / length * Self.sign(q.y))
        }
        if d.x > d.y {
            return SIMD2(Self.sign(q.x), 0)
        }
        return SIMD2(0, Self.sign(q.y))
    }

    /// Antialiased coverage of the panel at a pixel center, 0...1.
    func coverage(at pixel: SIMD2<Double>) -> Double {
        min(max(0.5 - signedDistance(at: pixel), 0), 1)
    }

    /// 1 at the outline, falling linearly to 0 at the rim's inner edge.
    /// Zero everywhere when the rim has no width.
    func rim(at pixel: SIMD2<Double>) -> Double {
        guard bezelWidth > 0 else { return 0 }
        let depth = max(-signedDistance(at: pixel), 0)
        return min(max(1 - depth / bezelWidth, 0), 1)
    }

    /// How far the glass sample moves toward the interior, in pixels.
    func displacement(at pixel: SIMD2<Double>) -> Double {
        let rim = rim(at: pixel)
        return maxDisplacement * rim * rim
    }

    /// Where the glass samples the background for a pixel, before the
    /// source clamp.
    func samplePosition(at pixel: SIMD2<Double>) -> SIMD2<Double> {
        pixel - outwardNormal(at: pixel) * displacement(at: pixel)
    }

    /// Edge illumination at a pixel, as a fraction of the way to white.
    func highlight(at pixel: SIMD2<Double>) -> Double {
        let rim = rim(at: pixel)
        let normal = outwardNormal(at: pixel)
        let facing = min(max(normal.x * Self.lightDirection.x + normal.y * Self.lightDirection.y, 0), 1)
        return edgeHighlight * rim * rim * rim * (0.4 + 0.6 * facing)
    }

    // MARK: Upload

    /// The record the panel pass reads.
    func uniforms(background: GWBackgroundUniforms, targetWidth: Int, targetHeight: Int) -> GWGlassUniforms {
        GWGlassUniforms(
            background: background,
            targetSize: SIMD2<Float>(Float(targetWidth), Float(targetHeight)),
            panelCenter: SIMD2<Float>(center),
            panelHalfSize: SIMD2<Float>(halfSize),
            cornerRadius: Float(cornerRadius),
            bezelWidth: Float(bezelWidth),
            normalRadius: Float(normalRadius),
            maxDisplacement: Float(maxDisplacement),
            edgeHighlight: Float(edgeHighlight),
            padding0: 0, padding1: 0, padding2: 0,
            tint: SIMD4<Float>(SIMD3<Float>(tintLinear), Float(tintStrength))
        )
    }

    // MARK: Helpers

    /// Matches MSL's `sign`: zero for zero.
    static func sign(_ x: Double) -> Double {
        x > 0 ? 1 : (x < 0 ? -1 : 0)
    }

    /// The sRGB transfer function, encoded to linear light.
    static func decodeSRGB(_ encoded: Double) -> Double {
        encoded <= 0.04045 ? encoded / 12.92 : Foundation.pow((encoded + 0.055) / 1.055, 2.4)
    }

    /// The sRGB transfer function, linear light to encoded.
    static func encodeSRGB(_ linear: Double) -> Double {
        let c = min(max(linear, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * Foundation.pow(c, 1 / 2.4) - 0.055
    }
}
