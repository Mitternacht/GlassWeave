import Foundation
internal import GlassWeaveShaderTypes

/// The thick-lens model (GW-22) on the CPU: the profiles, the refraction,
/// and the per-panel resolution of a ``GlassLens`` into pixels. The shader
/// (`Glass.metal`, "Thick lens") evaluates the same arithmetic in float;
/// this is the reference for it and the source of the one number the shader
/// cannot compute per pixel, the scale that keeps a no-fold lens from
/// folding.
enum GlassLensModel {
    /// The steepest surface slope the optics use, rise over run. The
    /// circular profile is vertical at the outline; clamping keeps the normal
    /// finite. The height there is 0 anyway, so the offset is unaffected.
    static let maximumSlope = 12.0

    /// The lowest slope of the sampled depth `d + offset(d)` a no-fold lens
    /// keeps: it may compress content but never turn it back.
    static let minimumDepthSlope = 0.05

    /// A profile `s(t)` and its slope `s'(t)` for a `GWLensProfile` code,
    /// `t` in 0...1 (the depth into the bevel over the bevel width). `a` and
    /// `b` are the profile's parameters (the squircle exponent; the ring's
    /// center and half-width).
    static func profile(_ code: UInt32, t: Double, a: Double, b: Double) -> (height: Double, slope: Double) {
        let t = min(max(t, 0), 1)
        switch code {
        case GWLensProfileCircular.rawValue, GWLensProfileDome.rawValue:
            let height = max(t * (2 - t), 0).squareRoot()
            return (height, height > 1e-6 ? (1 - t) / height : maximumSlope * 100)
        case GWLensProfileSquircle.rawValue:
            let n = max(a, 1)
            let u = 1 - t
            let power = pow(u, n)
            let inner = max(1 - power, 0)
            let height = pow(inner, 1 / n)
            let slope = inner > 1e-9 ? pow(u, n - 1) * pow(inner, 1 / n - 1) : maximumSlope * 100
            return (height, slope)
        case GWLensProfileChamfer.rawValue:
            let knee = 0.7
            let norm = (1 + knee) / 2
            if t < knee { return (t / norm, 1 / norm) }
            let u = t - knee
            return ((knee + u - u * u / (2 * (1 - knee))) / norm, (1 - u / (1 - knee)) / norm)
        case GWLensProfileRing.rawValue:
            let x = (t - a) / max(b, 1e-6)
            guard abs(x) < 1 else { return (0, 0) }
            let height = (1 - x * x).squareRoot()
            return (height, height > 1e-6 ? -x / (b * height) : -(x < 0 ? -1 : 1) * maximumSlope * 100)
        default:
            return (0, 0)
        }
    }

    /// How far inward a ray moves per unit of glass height, for a surface
    /// that rises `slope` per pixel toward the interior: the tangent of the
    /// angle `refract(-z, N, 1/ior)` leaves the vertical, for
    /// `N = normalize(slope outward, 1)`. Zero for a flat surface or an
    /// index of 1.
    static func inwardTangent(slope: Double, indexOfRefraction ior: Double) -> Double {
        let slope = min(max(slope, -maximumSlope), maximumSlope)
        let length = (slope * slope + 1).squareRoot()
        let sinI = slope / length, cosI = 1 / length
        let eta = 1 / ior
        let k = 1 - eta * eta * (1 - cosI * cosI)
        let along = eta * cosI - max(k, 0).squareRoot()
        let tx = along * sinI
        let tz = -eta + along * cosI
        return -tx / max(-tz, 1e-3)
    }

    /// The offset magnitude, in pixels, of a glass `height` high whose
    /// surface rises `slope` per pixel toward the interior, before the
    /// maximum and the fold scale.
    static func offset(height: Double, slope: Double, indexOfRefraction: Double) -> Double {
        height * inwardTangent(slope: slope, indexOfRefraction: indexOfRefraction)
    }

    /// The scale (at most 1) on every offset that keeps the sampled depth
    /// `d + offset(d)` rising along a bevel of `width` pixels, so a lens
    /// that may not fold never turns the content back: it only compresses or
    /// magnifies it. The profile is sampled along a straight bevel; a
    /// curved one (a corner, a dome) has the same radial profile.
    static func foldFreeScale(
        profile code: UInt32, a: Double, b: Double, thickness: Double, bevel: Double,
        indexOfRefraction ior: Double, maximumOffset: Double
    ) -> Double {
        guard thickness > 0, bevel > 0, ior > 1 else { return 1 }
        let count = 256
        var scale = 1.0
        for _ in 0..<8 {
            var previous = 0.0
            var steepest = 0.0
            for index in 1...count {
                let t = Double(index) / Double(count)
                let (height, slope) = profile(code, t: t - 0.5 / Double(count), a: a, b: b)
                let raw = offset(height: thickness * height, slope: thickness * slope / bevel, indexOfRefraction: ior)
                let current = min(raw * scale, maximumOffset)
                if index > 1 {
                    steepest = max(steepest, (previous - current) / (bevel / Double(count)))
                }
                previous = current
            }
            if steepest <= 1 - minimumDepthSlope { break }
            scale *= (1 - minimumDepthSlope) / steepest * 0.98
        }
        return scale
    }
}

extension GlassPanelGeometry {
    /// A lens resolved to pixels for one panel (GW-22).
    struct Lens: Equatable {
        /// A `GWLensProfile` code, never `GWLensProfileRim`.
        var profileCode: UInt32
        var thickness: Double
        var bevel: Double
        var fieldRadius: Double
        var indexOfRefraction: Double
        var maximumOffset: Double
        /// 1, or less when the lens may not fold.
        var offsetScale: Double
        var profileA: Double
        var profileB: Double
        /// 0...1; 0 for no dispersion.
        var dispersion: Double
        /// 0 (no dispersion), 3, or 6.
        var tapCount: UInt32

        /// Resolves a normalized lens, or returns `nil` when it changes
        /// nothing (the original rim without dispersion).
        init?(
            _ lens: GlassLens, displayScale: Double, cornerRadius: Double, bezelWidth: Double,
            halfSize: SIMD2<Double>
        ) {
            guard lens.isActive else { return nil }
            let inscribed = min(halfSize.x, halfSize.y)
            var code: UInt32
            var bevel = bezelWidth
            var a = 0.0, b = 0.0
            switch lens.profile {
            case .rim:
                // The original rim, with dispersion: no height field.
                code = GWLensProfileRim.rawValue
            case .circular:
                code = GWLensProfileCircular.rawValue
            case let .squircle(exponent):
                code = GWLensProfileSquircle.rawValue
                a = exponent
            case .chamfer:
                code = GWLensProfileChamfer.rawValue
            case .dome:
                code = GWLensProfileDome.rawValue
                bevel = inscribed
            case let .ring(center, width):
                code = GWLensProfileRing.rawValue
                // At least two pixels wide, so the ring does not alias.
                let widthPixels = max(width * displayScale, 2)
                let centerPixels = max(center * displayScale, widthPixels / 2)
                bevel = min(centerPixels + widthPixels / 2, inscribed)
                a = min(centerPixels / bevel, 1)
                b = widthPixels / 2 / bevel
            }
            profileCode = code
            thickness = code == GWLensProfileRim.rawValue ? 0 : lens.thickness * displayScale
            self.bevel = min(bevel, inscribed)
            fieldRadius = min(max(cornerRadius, self.bevel), inscribed)
            indexOfRefraction = lens.indexOfRefraction
            maximumOffset = lens.maximumOffset * displayScale
            profileA = a
            profileB = b
            dispersion = lens.dispersion
            tapCount = lens.dispersion > 0 ? (lens.dispersionTaps == .sixTap ? 6 : 3) : 0
            offsetScale = lens.allowsFold || code == GWLensProfileRim.rawValue ? 1 : GlassLensModel.foldFreeScale(
                profile: code, a: a, b: b, thickness: thickness, bevel: self.bevel,
                indexOfRefraction: indexOfRefraction, maximumOffset: maximumOffset
            )
        }
    }

    /// The panel's shape field: the rounded rectangle, with the lens depth
    /// taken from the lens's field radius (the normal radius without a lens).
    var shapeField: RoundedRectangleField {
        RoundedRectangleField(center: center, halfSize: halfSize, cornerRadius: cornerRadius, fieldRadius: lens?.fieldRadius ?? normalRadius)
    }

    /// The thick lens's height and slope at a pixel (the host profile only),
    /// from the shape field: height in pixels, and the height's gradient in
    /// pixels per pixel. `nil` without a lens.
    func lensHeightField(at pixel: SIMD2<Double>) -> (height: Double, gradient: SIMD2<Double>)? {
        guard let lens else { return nil }
        let field = shapeField
        let t = lens.bevel > 0 ? min(field.lensDepth(at: pixel) / lens.bevel, 1) : 1
        let (s, slope) = GlassLensModel.profile(lens.profileCode, t: t, a: lens.profileA, b: lens.profileB)
        guard t < 1, lens.bevel > 0 else { return (lens.thickness * s, .zero) }
        let rise = min(max(lens.thickness * slope / lens.bevel, -GlassLensModel.maximumSlope), GlassLensModel.maximumSlope)
        // The depth falls toward the outline, so the height's gradient
        // points inward: against the outward normal.
        return (lens.thickness * s, -field.outwardNormal(at: pixel) * rise)
    }

    /// Where the lens samples the background for a pixel, before the source
    /// clamp: the CPU reference of the shader's thick-lens sample position.
    /// `nil` without a lens.
    func lensSamplePosition(at pixel: SIMD2<Double>) -> SIMD2<Double>? {
        guard let lens, let (height, gradient) = lensHeightField(at: pixel), height > 0 else {
            return self.lens == nil ? nil : pixel
        }
        let slope = (gradient.x * gradient.x + gradient.y * gradient.y).squareRoot()
        var magnitude = GlassLensModel.offset(height: height, slope: slope, indexOfRefraction: lens.indexOfRefraction) * lens.offsetScale
        magnitude = min(magnitude, lens.maximumOffset)
        guard slope > 0 else { return pixel }
        return pixel + gradient / slope * magnitude
    }
}
