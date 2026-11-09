import CoreGraphics
import Foundation
internal import GlassWeaveShaderTypes

/// The touch response of one panel for one draw, in target pixels (GW-12).
///
/// The renderer builds it from the panel's ``GlassTouch``, the touches that
/// began inside the panel's outline and the effect time; the time dependence
/// is resolved here (``GlassTouch/state(of:at:)``), so the shader sees only
/// positions, radii and levels. The uploaded record is ``record``, bound as its
/// own fragment buffer, so ``GWGlassUniforms`` is unchanged.
struct GlassTouchModel: Equatable {
    /// The strength of the ring's catch light at ring strength 1: the share of
    /// the way to white the key light's side of the ring reaches.
    static let ringShine = 0.10
    /// The gleam's length scale along the rim, in points.
    static let gleamWidthPoints = 7.0
    /// How deep inside the outline the gleam reaches, in points.
    static let gleamBandPoints = 2.4
    /// The gleam's strength at gleam 1.
    static let gleamStrength = 0.6

    /// The touches that drive the panel with something to show, at most two.
    var states: [GlassTouchState]
    var record: GWTouchUniforms

    /// - Returns: `nil` when no touch that began inside the outline shows
    ///   anything at `effectTime`, so the panel draws without the response.
    init?(
        style: GlassTouch, touches: [GlassTouchPoint], effectTime: Double, displayScale: Double,
        geometry: GlassPanelGeometry
    ) {
        guard style.isActive, !touches.isEmpty else { return nil }
        var kept: [GWTouchPoint] = []
        var states: [GlassTouchState] = []
        for touch in touches.prefix(GlassTouch.maximumTouchCount) {
            let origin = SIMD2(Double(touch.origin.x), Double(touch.origin.y)) * displayScale
            // A touch drives the panel it began on.
            guard geometry.signedDistance(at: origin) <= 0 else { continue }
            let state = style.state(of: touch, at: effectTime)
            guard state.isVisible else { continue }
            let position = SIMD2(Double(touch.position.x), Double(touch.position.y)) * displayScale
            kept.append(GWTouchPoint(
                origin: SIMD2<Float>(origin),
                position: SIMD2<Float>(position),
                light: Float(state.light),
                lightRadius: Float(style.fingerRadius * state.lightScale * displayScale),
                ringRadius: Float(state.ringRadius * displayScale),
                ringWidth: Float(max(state.ringWidth * displayScale, 1)),
                ringAmplitude: Float(state.ringDisplacement * displayScale),
                ringStrength: Float(min(max(state.ringStrength, 0), 1)),
                gleam: Float(min(max(state.gleam, 0), 1)),
                rimDistance: Float(max(-geometry.signedDistance(at: position), 0))
            ))
            states.append(state)
        }
        guard !kept.isEmpty else { return nil }
        let empty = GWTouchPoint(origin: .zero, position: .zero, light: 0, lightRadius: 1, ringRadius: 0, ringWidth: 1, ringAmplitude: 0, ringStrength: 0, gleam: 0, rimDistance: 0)
        self.states = states
        record = GWTouchUniforms(
            count: UInt32(kept.count),
            fingerLight: Float(style.fingerLight),
            ringShine: Float(Self.ringShine),
            gleamReach: Float(max(style.fingerRadius, 24) * 1.3 * displayScale),
            gleamWidth: Float(Self.gleamWidthPoints * displayScale),
            gleamBand: Float(Self.gleamBandPoints * displayScale),
            gleamIntensity: Float(style.gleam * Self.gleamStrength),
            padding0: 0,
            points: (kept[0], kept.count > 1 ? kept[1] : empty)
        )
    }

    static func == (lhs: GlassTouchModel, rhs: GlassTouchModel) -> Bool {
        lhs.states == rhs.states && withUnsafeBytes(of: lhs.record) { left in
            withUnsafeBytes(of: rhs.record) { right in left.elementsEqual(right) }
        }
    }
}
