import Foundation
internal import GlassWeaveShaderTypes

extension GlassPanelGeometry {
    /// A visible ``GlassLight`` resolved for one draw (GW-21): linear-light
    /// colors with the hue drift applied, directions, lengths in pixels, and
    /// the flow and drift at the effect time the geometry was built for. The
    /// shader (`Glass.metal`, "Inner light") evaluates the rest per pixel; the
    /// model is documented in docs/glass-optics.md.
    struct Light: Equatable {
        /// One emitter as uploaded.
        struct Emitter: Equatable {
            var kind: UInt32
            /// The stops in linear light, hue drift applied; one to four.
            var colors: [SIMD3<Float>]
            var shape: SIMD4<Float>
            var motion: SIMD4<Float>
            var intensity: Float
            var seed: UInt32
        }

        var emitters: [Emitter]
        var composite: UInt32
        var centerFade: Float
        var piping: Float
        /// The width of the piped rim band in pixels; 0 draws no piping.
        var pipingWidth: Float
        var bodyScale: Float

        /// How much farther than its own reach an emitter's piping reaches.
        static let pipingReachFactor = 1.6

        /// Converts a normalized light at `effectTime`, or returns `nil`
        /// when it draws nothing. `halfSize` and `bezelWidth` are in pixels.
        init?(_ light: GlassLight, displayScale: Double, effectTime: Double, halfSize: SIMD2<Double>, bezelWidth: Double) {
            guard light.isVisible else { return nil }
            let phase = light.phase(at: effectTime)
            let turn = 2 * Double.pi
            let minHalf = min(halfSize.x, halfSize.y)
            let hue = turn * light.hueDrift * phase
            var resolved: [Emitter] = []
            for (index, emitter) in light.emitters.enumerated() where emitter.intensity > 0 && !emitter.colors.isEmpty {
                var colors = emitter.colors.map {
                    Self.rotateHue(
                        SIMD3(
                            GlowColorModel.decodeSRGB($0.red), GlowColorModel.decodeSRGB($0.green), GlowColorModel.decodeSRGB($0.blue)
                        ),
                        by: hue
                    )
                }
                let shift = Float(2 * emitter.flow * phase)
                let drift = SIMD2(Foundation.cos(turn * phase), Foundation.sin(turn * phase)) * emitter.drift
                var kind = GWLightKindBand.rawValue
                var shape = SIMD4<Float>.zero
                var motionX = shift
                var reach = 1.0
                switch emitter.placement {
                case let .band(angle, bandReach):
                    let a = angle * .pi / 180
                    let direction = SIMD2(Foundation.sin(a), -Foundation.cos(a))
                    let along = abs(direction.x) * halfSize.x + abs(direction.y) * halfSize.y
                    shape = SIMD4(Float(direction.x), Float(direction.y), Float(bandReach), Float(along))
                    reach = bandReach * along
                case let .arc(angle, span, arcReach):
                    kind = GWLightKindArc.rawValue
                    let reachPixels = arcReach * minHalf
                    shape = SIMD4(Float(angle / 360), Float(span / 720), Float(reachPixels), 0)
                    reach = reachPixels
                case let .point(x, y, radius, stretch):
                    kind = GWLightKindPoint.rawValue
                    let radiusPixels = radius * minHalf
                    shape = SIMD4(Float(x), Float(y), Float(radiusPixels), Float(stretch))
                    reach = radiusPixels * max(stretch, 1)
                case let .field(warp):
                    kind = GWLightKindField.rawValue
                    let loop = turn * emitter.flow * phase
                    shape = SIMD4(Float(warp), Float(0.6 * Foundation.cos(loop)), Float(0.6 * Foundation.sin(loop)), 0)
                    motionX = 0
                    reach = 1 / Self.pipingReachFactor
                    // A field's stops are its four corners.
                    while colors.count < 4 { colors.append(colors[colors.count - 1]) }
                }
                resolved.append(Emitter(
                    kind: kind,
                    colors: colors.map { SIMD3<Float>($0) },
                    shape: shape,
                    motion: SIMD4(motionX, Float(drift.x), Float(drift.y), Float(reach * Self.pipingReachFactor)),
                    intensity: Float(emitter.intensity),
                    seed: UInt32(truncatingIfNeeded: index &* 0x9e37_79b9) &+ 0x2545_f491
                ))
            }
            guard !resolved.isEmpty else { return nil }
            emitters = resolved
            composite = light.composite == .paint ? GWLightCompositePaint.rawValue : GWLightCompositeLight.rawValue
            centerFade = Float(light.centerFade)
            piping = Float(light.piping)
            pipingWidth = Float(light.pipingWidth.map { $0 * displayScale } ?? bezelWidth)
            bodyScale = Float(light.body)
        }

        /// Rotates a linear-light color's hue by `angle` radians around the
        /// gray axis (Rodrigues' rotation), clamped to 0...1. The component
        /// along the gray axis, which sets most of the brightness, stays.
        static func rotateHue(_ color: SIMD3<Double>, by angle: Double) -> SIMD3<Double> {
            guard angle != 0 else { return color }
            let c = Foundation.cos(angle), s = Foundation.sin(angle)
            let k = SIMD3<Double>(repeating: 1 / 3.0.squareRoot())
            let cross = SIMD3(k.y * color.z - k.z * color.y, k.z * color.x - k.x * color.z, k.x * color.y - k.y * color.x)
            let rotated = color * c + cross * s + k * ((k * color).sum() * (1 - c))
            return SIMD3(min(max(rotated.x, 0), 1), min(max(rotated.y, 0), 1), min(max(rotated.z, 0), 1))
        }

        /// The emitter records, padded with zeros to four.
        var records: (GWLightEmitter, GWLightEmitter, GWLightEmitter, GWLightEmitter) {
            let lane = { (emitter: Emitter, index: Int) -> SIMD4<Float> in
                index < emitter.colors.count ? SIMD4(emitter.colors[index], 0) : .zero
            }
            let record = { (index: Int) -> GWLightEmitter in
                guard index < emitters.count else {
                    return GWLightEmitter(
                        color0: .zero, color1: .zero, color2: .zero, color3: .zero, shape: .zero, motion: .zero,
                        kind: GWLightKindNone.rawValue, colorCount: 0, intensity: 0, seed: 0
                    )
                }
                let emitter = emitters[index]
                return GWLightEmitter(
                    color0: lane(emitter, 0), color1: lane(emitter, 1), color2: lane(emitter, 2), color3: lane(emitter, 3),
                    shape: emitter.shape, motion: emitter.motion,
                    kind: emitter.kind, colorCount: UInt32(emitter.colors.count),
                    intensity: emitter.intensity, seed: emitter.seed
                )
            }
            return (record(0), record(1), record(2), record(3))
        }
    }
}

extension GlassPanelGeometry.Light {
    /// Four zero records, for a panel without light.
    static var emptyRecords: (GWLightEmitter, GWLightEmitter, GWLightEmitter, GWLightEmitter) {
        let none = GWLightEmitter(
            color0: .zero, color1: .zero, color2: .zero, color3: .zero, shape: .zero, motion: .zero,
            kind: GWLightKindNone.rawValue, colorCount: 0, intensity: 0, seed: 0
        )
        return (none, none, none, none)
    }
}
