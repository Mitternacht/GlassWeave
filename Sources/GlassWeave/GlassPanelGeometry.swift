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
    /// The glow in target pixels and linear light, or `nil` when the panel's
    /// glow draws nothing.
    var glow: Glow?
    /// The interior in linear light at the effect time the geometry was
    /// built for, or `nil` when the panel's interior draws nothing (GW-19;
    /// the model is in GlassInteriorModel.swift).
    var interior: Interior?

    /// A visible ``GlassGlow`` converted to target pixels and linear light.
    struct Glow: Equatable {
        /// Stop colors in linear light, ordered by angle.
        var colorsLinear: [SIMD3<Double>]
        /// Stop angles in turns (0 at the top, clockwise), ascending, 0..<1.
        var stopTurns: [Double]
        /// Unit vector toward the light, y down.
        var lightDirection: SIMD2<Double>
        var rimWidth: Double
        /// Width of the rim's soft inner edge: at least one pixel.
        var rimFeather: Double
        /// Zero when the glow has no rim.
        var rimIntensity: Double
        var innerRadius: Double
        var innerIntensity: Double
        var centerOpacity: Double
        var directionality: Double
        /// Corner radius of the field that orients the light:
        /// `max(cornerRadius, rimWidth + rimFeather, innerRadius)`, at most
        /// half the panel's shorter side. The halo uses the same field
        /// outside the outline, so the light is continuous across it.
        var normalRadius: Double
        /// How far the halo reaches outside the outline, in pixels; zero
        /// without a halo.
        var haloRadius: Double
        /// Halo opacity at the outline, with the pulse level applied; zero
        /// without a halo.
        var haloIntensity: Double
        /// The pulse level at the effect time the geometry was built for
        /// (``GlassGlow/pulseLevel(at:)``), already applied to
        /// ``rimIntensity``, ``innerIntensity``, and ``haloIntensity``.
        var pulseLevel: Double
    }

    /// Light direction for edge illumination (from the upper left, y down).
    static let lightDirection = SIMD2<Double>(-1, -1) / 2.0.squareRoot()

    /// - Parameters:
    ///   - panel: A panel that has passed ``GlassPanel/normalized()``.
    ///   - displayScale: Pixels per point, finite and positive.
    ///   - effectTime: Seconds on the effect clock, finite; sets the pulse
    ///     level and the interior's phase.
    init(panel: GlassPanel, displayScale: Double, effectTime: Double = 0) {
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
        glow = Self.glow(
            parameters.glow, displayScale: displayScale, effectTime: effectTime,
            cornerRadius: cornerRadius, halfSize: halfSize
        )
        interior = Interior(
            parameters.interior, displayScale: displayScale, effectTime: effectTime,
            halfSize: halfSize / displayScale, exitHeight: (glow?.haloRadius ?? 0) / displayScale
        )
    }

    /// Converts a normalized glow, or returns `nil` when it draws nothing.
    private static func glow(
        _ glow: GlassGlow, displayScale: Double, effectTime: Double, cornerRadius: Double, halfSize: SIMD2<Double>
    ) -> Glow? {
        guard glow.isVisible else { return nil }
        let pulse = glow.pulseLevel(at: effectTime)
        let hasRim = glow.rimIntensity > 0 && (glow.rimWidth > 0 || glow.rimSoftness > 0)
        let rimWidth = glow.rimWidth * displayScale
        let rimFeather = max(glow.rimSoftness * displayScale, 1)
        let innerRadius = glow.innerGlowRadius * displayScale
        let light = glow.lightAngle * .pi / 180
        return Glow(
            colorsLinear: glow.colors.map { SIMD3(decodeSRGB($0.red), decodeSRGB($0.green), decodeSRGB($0.blue)) },
            stopTurns: glow.colors.map { $0.angle / 360 },
            lightDirection: SIMD2(Foundation.sin(light), -Foundation.cos(light)),
            rimWidth: rimWidth,
            rimFeather: rimFeather,
            rimIntensity: hasRim ? glow.rimIntensity * pulse : 0,
            innerRadius: innerRadius,
            innerIntensity: glow.innerGlowIntensity * pulse,
            centerOpacity: glow.centerOpacity,
            directionality: glow.directionality,
            normalRadius: min(max(cornerRadius, rimWidth + rimFeather, innerRadius), min(halfSize.x, halfSize.y)),
            haloRadius: glow.hasHalo ? glow.haloRadius * displayScale : 0,
            haloIntensity: glow.hasHalo ? glow.haloIntensity * pulse : 0,
            pulseLevel: pulse
        )
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
        outwardNormal(at: pixel, radius: normalRadius)
    }

    /// The outward unit normal of the panel rectangle with corner radius
    /// `radius`: radial in the corner regions, axis-aligned along the edges.
    func outwardNormal(at pixel: SIMD2<Double>, radius: Double) -> SIMD2<Double> {
        let q = pixel - center
        let d = abs(q) - (halfSize - radius)
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

    // MARK: Glow

    /// The angle of a pixel around the panel's center, in turns (0 at the
    /// top, clockwise), with the panel scaled to a square so 1/8 turn always
    /// points at the top-right corner. Zero at the exact center.
    func glowTurn(at pixel: SIMD2<Double>) -> Double {
        let p = (pixel - center) / halfSize
        guard p.x != 0 || p.y != 0 else { return 0 }
        let turn = Foundation.atan2(p.x, -p.y) / (2 * .pi)
        return turn - turn.rounded(.down)
    }

    /// The glow color at an angle in turns, in linear light: linear
    /// interpolation between the neighbouring stops around the circle.
    func glowColor(atTurn turn: Double) -> SIMD3<Double> {
        guard let glow else { return .zero }
        return GlowColorModel.color(atTurn: turn, colorsLinear: glow.colorsLinear, stopTurns: glow.stopTurns)
    }

    /// The light factor at a pixel:
    /// `(1 − directionality) + directionality × ((1 + n·L) / 2)²`.
    func glowLight(at pixel: SIMD2<Double>) -> Double {
        guard let glow else { return 0 }
        let normal = outwardNormal(at: pixel, radius: glow.normalRadius)
        let facing = (1 + normal.x * glow.lightDirection.x + normal.y * glow.lightDirection.y) / 2
        return (1 - glow.directionality) + glow.directionality * facing * facing
    }

    /// The glow layer's opacity at a pixel inside the panel:
    /// `1 − (1 − center)(1 − inner)(1 − rim)`. Zero without a glow.
    func glowAlpha(at pixel: SIMD2<Double>) -> Double {
        guard let glow else { return 0 }
        let depth = max(-signedDistance(at: pixel), 0)
        let light = glowLight(at: pixel)
        var rim = 0.0
        if glow.rimIntensity > 0 {
            rim = glow.rimIntensity
                * (1 - Self.smoothstep(glow.rimWidth, glow.rimWidth + glow.rimFeather, depth)) * light
        }
        var inner = 0.0
        if glow.innerRadius > 0 {
            let t = min(max(depth / glow.innerRadius, 0), 1)
            inner = glow.innerIntensity * (1 - t) * (1 - t) * light
        }
        return 1 - (1 - glow.centerOpacity) * (1 - inner) * (1 - rim)
    }

    /// The halo's opacity at a pixel, for the part of it outside the
    /// outline: `haloIntensity × (1 − s / haloRadius)² × light` at distance
    /// `s = max(signedDistance, 0)` from the outline, exactly zero from the
    /// halo radius on. Zero without a halo. The shader evaluates it only
    /// where the panel's coverage is below 1.
    func haloAlpha(at pixel: SIMD2<Double>) -> Double {
        guard let glow, glow.haloRadius > 0 else { return 0 }
        let distance = max(signedDistance(at: pixel), 0)
        let t = min(distance / glow.haloRadius, 1)
        return glow.haloIntensity * (1 - t) * (1 - t) * glowLight(at: pixel)
    }

    /// How far the panel's quad reaches beyond the panel rectangle on every
    /// side, in pixels: one pixel for the antialiased outline, plus the
    /// halo radius.
    var quadOutset: Double {
        1 + (glow?.haloRadius ?? 0)
    }

    /// Whether the panel's quad (``quadOutset`` around the rectangle) covers
    /// part of a target of `width` × `height` pixels. A panel without area
    /// covers nothing.
    func quadOverlapsTarget(width: Int, height: Int) -> Bool {
        guard !isEmpty, width > 0, height > 0 else { return false }
        let reach = halfSize + quadOutset
        let minimum = center - reach
        let maximum = center + reach
        return maximum.x > 0 && maximum.y > 0 && minimum.x < Double(width) && minimum.y < Double(height)
    }

    /// The 4 × 4 ordered-dither (Bayer) matrix, row by row.
    static let bayer: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

    /// The dither offset added to an encoded glow pixel at `column`, `row`,
    /// in 8-bit steps: −0.47...0.47.
    static func ditherOffset(column: Int, row: Int) -> Double {
        (bayer[(column & 3) + 4 * (row & 3)] + 0.5) / 16 - 0.5
    }

    /// MSL's `smoothstep`.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
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
            tint: SIMD4<Float>(SIMD3<Float>(tintLinear), Float(tintStrength)),
            glowColor0: glowColorLane(0),
            glowColor1: glowColorLane(1),
            glowColor2: glowColorLane(2),
            glowColor3: glowColorLane(3),
            glowStopTurns: SIMD4<Float>((0..<4).map { index in
                guard let turns = glow?.stopTurns, index < turns.count else { return 0 }
                return Float(turns[index])
            }),
            glowLightDirection: SIMD2<Float>(glow?.lightDirection ?? .zero),
            glowStopCount: UInt32(glow?.colorsLinear.count ?? 0),
            glowRimWidth: Float(glow?.rimWidth ?? 0),
            glowRimFeather: Float(glow?.rimFeather ?? 0),
            glowRimIntensity: Float(glow?.rimIntensity ?? 0),
            glowInnerRadius: Float(glow?.innerRadius ?? 0),
            glowInnerIntensity: Float(glow?.innerIntensity ?? 0),
            glowCenterOpacity: Float(glow?.centerOpacity ?? 0),
            glowDirectionality: Float(glow?.directionality ?? 0),
            glowNormalRadius: Float(glow?.normalRadius ?? 0),
            padding3: 0,
            glowHaloRadius: Float(glow?.haloRadius ?? 0),
            glowHaloIntensity: Float(glow?.haloIntensity ?? 0),
            padding4: 0, padding5: 0,
            interiorColor0: interiorColorLane(0),
            interiorColor1: interiorColorLane(1),
            interiorColor2: interiorColorLane(2),
            interiorEffect: interior?.effectCode ?? GWInteriorEffectNone.rawValue,
            interiorColorCount: UInt32(interior?.colorsLinear.count ?? 0),
            interiorSeed: interior?.seed ?? 0,
            interiorIntensity: Float(interior?.intensity ?? 0),
            interiorPhase: interior?.phase ?? 0,
            interiorCenterFade: Float(interior?.centerFade ?? 0),
            interiorPixelsPerPoint: Float(interior?.pixelsPerPoint ?? 0),
            padding6: 0,
            interiorSparks: sparkLanes
        )
    }

    /// The twelve uploaded sparks (embers only; zero otherwise).
    private var sparkLanes: (
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>
    ) {
        let s = (interior?.sparks ?? []) + Array(repeating: .zero, count: 12)
        return (s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10], s[11])
    }

    /// One interior ramp color for upload: linear RGB with `w` zero, or zero
    /// when the color does not exist.
    private func interiorColorLane(_ index: Int) -> SIMD4<Float> {
        guard let colors = interior?.colorsLinear, index < colors.count else { return .zero }
        return SIMD4<Float>(SIMD3<Float>(colors[index]), 0)
    }

    /// One stop color for upload: linear RGB with `w` zero, or zero when
    /// the stop does not exist.
    private func glowColorLane(_ index: Int) -> SIMD4<Float> {
        guard let colors = glow?.colorsLinear, index < colors.count else { return .zero }
        return SIMD4<Float>(SIMD3<Float>(colors[index]), 0)
    }

    // MARK: Helpers

    /// Matches MSL's `sign`: zero for zero.
    static func sign(_ x: Double) -> Double {
        x > 0 ? 1 : (x < 0 ? -1 : 0)
    }

    /// The sRGB transfer function, encoded to linear light.
    static func decodeSRGB(_ encoded: Double) -> Double {
        GlowColorModel.decodeSRGB(encoded)
    }

    /// The sRGB transfer function, linear light to encoded.
    static func encodeSRGB(_ linear: Double) -> Double {
        GlowColorModel.encodeSRGB(linear)
    }
}
