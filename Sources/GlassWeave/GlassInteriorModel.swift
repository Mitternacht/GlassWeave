import Foundation
internal import GlassWeaveShaderTypes

extension GlassPanelGeometry {
    /// A visible ``GlassInterior`` at one effect time, in linear light
    /// (GW-19).
    struct Interior: Equatable {
        var effect: GlassInterior.Effect
        /// The ramp in linear light, faintest first.
        var colorsLinear: [SIMD3<Double>]
        var intensity: Double
        /// Interior time in seconds, `0..<64`, as uploaded (a `Float`).
        var phase: Float
        var seed: UInt32
        var centerFade: Double
        /// The display scale: the pattern is laid out in points.
        var pixelsPerPoint: Double

        /// Converts a normalized interior at `effectTime`, or returns `nil`
        /// when it draws nothing.
        init?(_ interior: GlassInterior, displayScale: Double, effectTime: Double) {
            guard interior.isVisible else { return nil }
            effect = interior.effect
            colorsLinear = interior.colors.map {
                SIMD3(GlowColorModel.decodeSRGB($0.red), GlowColorModel.decodeSRGB($0.green), GlowColorModel.decodeSRGB($0.blue))
            }
            intensity = interior.intensity
            // A phase just below the loop's end can round up to it as a
            // Float; the pattern there equals the pattern at 0.
            let phase = Float(interior.phase(at: effectTime))
            self.phase = phase >= Float(GlassInterior.loopDuration) ? 0 : phase
            seed = interior.seed
            centerFade = interior.centerFade
            pixelsPerPoint = displayScale
        }

        /// The record's `interiorEffect` value.
        var effectCode: UInt32 {
            switch effect {
            case .none: GWInteriorEffectNone.rawValue
            case .energy: GWInteriorEffectEnergy.rawValue
            case .rays: GWInteriorEffectRays.rawValue
            case .embers: GWInteriorEffectEmbers.rawValue
            }
        }
    }

    // MARK: The interior model (mirrored by Glass.metal)

    /// The depth inside the outline as a fraction of half the panel's
    /// shorter side: 0 at the outline, 1 at the deepest points.
    func interiorDepthFraction(at pixel: SIMD2<Double>) -> Double {
        let depth = max(-signedDistance(at: pixel), 0)
        return min(max(depth / min(halfSize.x, halfSize.y), 0), 1)
    }

    /// The center fade at a pixel inside the panel:
    /// `1 − centerFade × smoothstep(0.3, 0.85, w)`. 1 without an interior.
    func interiorFade(at pixel: SIMD2<Double>) -> Double {
        guard let interior else { return 1 }
        return 1 - interior.centerFade * Self.smoothstep(0.3, 0.85, interiorDepthFraction(at: pixel))
    }

    /// The pattern's value (0...1) at a pixel inside the panel, before the
    /// fade and intensity. 0 without an interior.
    func interiorValue(at pixel: SIMD2<Double>) -> Double {
        guard let interior else { return 0 }
        let scale = interior.pixelsPerPoint
        let u = (pixel - center) / scale
        let half = halfSize / scale
        let phase = Double(interior.phase)
        switch interior.effect {
        case .none:
            return 0
        case .energy:
            return InteriorPattern.energy(u, size: InteriorPattern.size(half), w: interiorDepthFraction(at: pixel), phase: phase, seed: interior.seed)
        case .rays:
            return InteriorPattern.rays(u, size: InteriorPattern.size(half), phase: phase, seed: interior.seed)
        case .embers:
            return max(
                InteriorPattern.flames(u, half: half, phase: phase, seed: interior.seed),
                InteriorPattern.sparks(u, half: half, exitHeight: (glow?.haloRadius ?? 0) / scale, phase: phase, seed: interior.seed)
            )
        }
    }

    /// The interior's ramp color at value `e`, in linear light.
    func interiorRamp(_ e: Double) -> SIMD3<Double> {
        guard let colors = interior?.colorsLinear, let first = colors.first else { return .zero }
        switch colors.count {
        case 1: return first
        case 2: return colors[0] + (colors[1] - colors[0]) * e
        default:
            return e < 0.5
                ? colors[0] + (colors[1] - colors[0]) * (e * 2)
                : colors[1] + (colors[2] - colors[1]) * (e * 2 - 1)
        }
    }

    /// The interior's light at a pixel the panel covers: the ramp color and
    /// the opacity `e × intensity × fade` with which it is screened over the
    /// glowing glass. Opacity 0 without an interior and where the fade is 0
    /// (the shader skips the pattern there).
    func interiorLight(at pixel: SIMD2<Double>) -> (color: SIMD3<Double>, alpha: Double) {
        guard let interior else { return (.zero, 0) }
        let fade = interiorFade(at: pixel)
        guard fade > 0 else { return (.zero, 0) }
        let e = interiorValue(at: pixel)
        return (interiorRamp(e), e * interior.intensity * fade)
    }

    /// Embers' spark light outside the outline: only for embers with a halo,
    /// above the panel's center line, within the halo radius, where the
    /// panel's coverage is below 1; opacity
    /// `spark × intensity × (1 − s / haloRadius)²` at distance `s`.
    func exteriorSparkLight(at pixel: SIMD2<Double>) -> (color: SIMD3<Double>, alpha: Double) {
        guard let interior, interior.effect == .embers, let haloRadius = glow?.haloRadius, haloRadius > 0 else {
            return (.zero, 0)
        }
        let distance = signedDistance(at: pixel)
        guard coverage(at: pixel) < 1, pixel.y - center.y < 0, distance < haloRadius else { return (.zero, 0) }
        let scale = interior.pixelsPerPoint
        let e = InteriorPattern.sparks(
            (pixel - center) / scale, half: halfSize / scale, exitHeight: haloRadius / scale,
            phase: Double(interior.phase), seed: interior.seed
        )
        let t = min(max(distance, 0) / haloRadius, 1)
        return (interiorRamp(e), e * interior.intensity * (1 - t) * (1 - t))
    }
}

/// The interior patterns on the CPU, in double precision, mirroring the
/// functions of the same names in `Glass.metal`. Hashes are exact integer
/// arithmetic on both sides.
enum InteriorPattern {
    /// The lowbias32 integer hash.
    static func hash(_ value: UInt32) -> UInt32 {
        var x = value
        x ^= x >> 16
        x &*= 0x7feb_352d
        x ^= x >> 15
        x &*= 0x846c_a68b
        x ^= x >> 16
        return x
    }

    /// The top 24 bits of a hash in [0, 1).
    static func unit(_ h: UInt32) -> Double {
        Double(h >> 8) / 16_777_216
    }

    static func wrap(_ i: Int, _ period: Int) -> Int {
        let r = i % period
        return r < 0 ? r + period : r
    }

    static func lattice2(_ x: Int, _ y: Int, _ period: SIMD2<Int>, _ seed: UInt32) -> Double {
        let wx = UInt32(wrap(x, period.x)), wy = UInt32(wrap(y, period.y))
        return unit(hash(wx &* 0x8da6_b343 &+ wy &* 0xd816_3841 &+ seed))
    }

    static func lattice3(_ x: Int, _ y: Int, _ z: Int, _ period: SIMD3<Int>, _ seed: UInt32) -> Double {
        let wx = UInt32(wrap(x, period.x)), wy = UInt32(wrap(y, period.y)), wz = UInt32(wrap(z, period.z))
        return unit(hash(wx &* 0x8da6_b343 &+ wy &* 0xd816_3841 &+ wz &* 0xcb1a_b31f &+ seed))
    }

    static func noise2(_ p: SIMD2<Double>, _ period: SIMD2<Int>, _ seed: UInt32) -> Double {
        let base = SIMD2(p.x.rounded(.down), p.y.rounded(.down))
        let cx = Int(base.x), cy = Int(base.y)
        let f = p - base
        let s = f * f * (3 - 2 * f)
        let v00 = lattice2(cx, cy, period, seed)
        let v10 = lattice2(cx + 1, cy, period, seed)
        let v01 = lattice2(cx, cy + 1, period, seed)
        let v11 = lattice2(cx + 1, cy + 1, period, seed)
        let x0 = v00 + (v10 - v00) * s.x
        let x1 = v01 + (v11 - v01) * s.x
        return x0 + (x1 - x0) * s.y
    }

    static func noise3(_ p: SIMD3<Double>, _ period: SIMD3<Int>, _ seed: UInt32) -> Double {
        let base = SIMD3(p.x.rounded(.down), p.y.rounded(.down), p.z.rounded(.down))
        let cx = Int(base.x), cy = Int(base.y), cz = Int(base.z)
        let f = p - base
        let s = f * f * (3 - 2 * f)
        let v000 = lattice3(cx, cy, cz, period, seed)
        let v100 = lattice3(cx + 1, cy, cz, period, seed)
        let v010 = lattice3(cx, cy + 1, cz, period, seed)
        let v110 = lattice3(cx + 1, cy + 1, cz, period, seed)
        let v001 = lattice3(cx, cy, cz + 1, period, seed)
        let v101 = lattice3(cx + 1, cy, cz + 1, period, seed)
        let v011 = lattice3(cx, cy + 1, cz + 1, period, seed)
        let v111 = lattice3(cx + 1, cy + 1, cz + 1, period, seed)
        let x00 = v000 + (v100 - v000) * s.x
        let x10 = v010 + (v110 - v010) * s.x
        let x01 = v001 + (v101 - v001) * s.x
        let x11 = v011 + (v111 - v011) * s.x
        let y0 = x00 + (x10 - x00) * s.y
        let y1 = x01 + (x11 - x01) * s.y
        return y0 + (y1 - y0) * s.z
    }

    static func fbm3(_ p: SIMD3<Double>, _ period: SIMD3<Int>, _ seed: UInt32) -> Double {
        var p = p, period = period
        var sum = 0.0, amplitude = 0.5
        for octave in 0..<UInt32(3) {
            sum += amplitude * noise3(p, period, seed &+ octave &* 0x9e37_79b9)
            p *= 2
            period &*= 2
            amplitude *= 0.5
        }
        return sum / 0.875
    }

    static func wave(_ x: Double) -> Double {
        let t = abs(2 * (x - x.rounded(.down)) - 1)
        return 2 * t * t * (3 - 2 * t) - 1
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        GlassPanelGeometry.smoothstep(edge0, edge1, x)
    }

    static func saturate(_ x: Double) -> Double {
        min(max(x, 0), 1)
    }

    /// Half the shorter side, at least 12 points.
    static func size(_ half: SIMD2<Double>) -> Double {
        max(min(half.x, half.y), 12)
    }

    static func energy(_ u: SIMD2<Double>, size: Double, w: Double, phase: Double, seed: UInt32) -> Double {
        let p0 = u / size
        let angle = 2 * Double.pi * (phase / 64) + 0.9 * min((p0.x * p0.x + p0.y * p0.y).squareRoot(), 1)
        let c = Foundation.cos(angle), s = Foundation.sin(angle)
        let p = SIMD2(c * p0.x - s * p0.y, s * p0.x + c * p0.y) * 2.2
        let z = phase * 0.5
        let period = SIMD3(4096, 4096, 32)
        let wx = fbm3(SIMD3(p.x, p.y, z), period, seed)
        let wy = fbm3(SIMD3(p.x + 19, p.y + 7, z), period, seed &+ 0x51ed_270b)
        let warped = p + 1.4 * (SIMD2(wx, wy) - 0.5)
        let n = fbm3(SIMD3(warped.x, warped.y, z + 11), period, seed &+ 0xa3c5_9ac3)
        let offset = abs(n - 0.5)
        let core = 1 - smoothstep(0, 0.045, offset)
        let haze = 1 - smoothstep(0, 0.16, offset)
        return saturate(0.85 * core * core + 0.3 * haze * haze) * (0.45 + 0.55 * (1 - w))
    }

    static func rayLayer(_ turn: Double, r: Double, count: Int, minWidth: Double, maxWidth: Double, z: Double, seed: UInt32) -> Double {
        let x = turn * Double(count)
        let base = x.rounded(.down)
        let cell = wrap(Int(base), count)
        let f = x - base
        let h = hash(UInt32(cell) &* 0x8da6_b343 &+ seed)
        let center = 0.3 + 0.4 * unit(hash(h &+ 1))
        let width = minWidth + (maxWidth - minWidth) * unit(hash(h &+ 2))
        let cellPoints = max(r * (2 * .pi) / Double(count), 0.001)
        let drawn = min(max(width, 0.75 / cellPoints), 0.28)
        let profile = 1 - smoothstep(0, drawn, abs(f - center))
        let twinkle = noise2(SIMD2(Double(cell), z), SIMD2(count, 32), seed &+ 0x3c6e_f372)
        return profile * profile * (width / drawn) * (0.35 + 0.65 * twinkle)
    }

    static func rays(_ u: SIMD2<Double>, size: Double, phase: Double, seed: UInt32) -> Double {
        let r = (u.x * u.x + u.y * u.y).squareRoot()
        guard r > 0 else { return 0 }
        var turn = Foundation.atan2(u.x, -u.y) / (2 * .pi)
        turn -= turn.rounded(.down)
        let z = phase * 0.5
        let beams = rayLayer(turn + 2 * phase / 64, r: r, count: 13, minWidth: 0.1, maxWidth: 0.28, z: z, seed: seed)
        let rays = rayLayer(turn - phase / 64, r: r, count: 29, minWidth: 0.03, maxWidth: 0.09, z: z + 7, seed: seed &+ 0x68e3_1da4)
        let flow = noise2(SIMD2(turn * 7, r / size * 2.5 - phase * 0.75), SIMD2(7, 48), seed &+ 0xb529_7a4d)
        let resolved = smoothstep(1.5, 4.5, r * (2 * .pi / 29))
        return saturate((0.55 * beams + rays) * (0.4 + 0.6 * flow)) * resolved
    }

    static func flames(_ u: SIMD2<Double>, half: SIMD2<Double>, phase: Double, seed: UInt32) -> Double {
        let above = half.y - u.y
        let y = above / (1.3 * half.y)
        let n = fbm3(SIMD3(u.x / 9, above / 22 - phase * 0.75, phase * 0.5), SIMD3(4096, 48, 32), seed)
        let tongues = noise2(SIMD2(u.x / 16, phase * 0.25), SIMD2(4096, 16), seed &+ 0x2545_f491)
        let v = (1 - y / (0.45 + 0.9 * tongues)) + (n - 0.5) * 0.8
        return smoothstep(0, 1.25, v)
    }

    static func sparks(_ u: SIMD2<Double>, half: SIMD2<Double>, exitHeight: Double, phase: Double, seed: UInt32) -> Double {
        let start = 0.16 * half.y
        let travel = 2 * half.y + exitHeight - start
        var spark = 0.0
        for i in UInt32(0)..<12 {
            let h = hash(seed &+ 0x9e37_79b9 &* (i + 1))
            let r0 = unit(hash(h &+ 1)), r1 = unit(hash(h &+ 2)), r2 = unit(hash(h &+ 3)), r3 = unit(hash(h &+ 4))
            var life = r1 + phase * Double(12 + h % 21) / 64
            life -= life.rounded(.down)
            let above = start + life * travel
            let sway = (2 + 4 * r2) * wave(above / (16 + 14 * r2) + r3)
            let center = SIMD2((r0 * 2 - 1) * max(half.x - 3, 0) + sway, half.y - above)
            let radius = 1.6 + 1.2 * r3
            let d = u - center
            let dd = (d.x * d.x + d.y * d.y) / (radius * radius)
            if dd < 9 {
                let core = dd < 1 ? (1 - dd) * (1 - dd) : 0
                let glow = (1 - dd / 9) * (1 - dd / 9)
                let fade = smoothstep(0, 0.05, life) * (1 - smoothstep(0.7, 1, life))
                spark = max(spark, max(core, 0.45 * glow) * fade)
            }
        }
        return spark
    }
}
