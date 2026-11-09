import CoreGraphics
import Foundation
internal import GlassWeaveShaderTypes

/// The outline of a glass panel (GW-26): the rounded rectangle, an ellipse, a
/// squircle, or a smooth blob.
///
/// > Important: Experimental. This API may change before a stable release.
///
/// Apple's native glass takes a shape from a fixed set. GlassWeave's own glass
/// takes any of these, and **every** effect follows the outline: the rim
/// refraction and the thick lens, the glow's rim, inner glow and halo, the
/// interior and the inner light, the light model's Fresnel line and
/// reflections, and the grounding's shadows and caustic. The rounded
/// rectangle, the default, is drawn exactly as before, byte for byte, by a
/// pipeline variant that does not contain the shape code.
///
/// | Shape | Meaning |
/// | --- | --- |
/// | ``roundedRectangle`` | The panel's frame with ``GlassParameters/cornerRadius``. The default. |
/// | ``ellipse`` | The ellipse inscribed in the frame; a circle in a square frame. ``GlassParameters/cornerRadius`` is ignored. |
/// | ``superellipse(exponent:)`` | `|x/a|ⁿ + |y/b|ⁿ = 1` inscribed in the frame, `n` clamped to 2...10: 2 is the ellipse, 4 the familiar squircle, 10 nearly a rectangle. |
/// | ``blob(_:)`` | A smooth union of up to ``maximumPrimitives`` circles, capsules and rotated rounded boxes (``GlassBlob``), with an optional wobble. |
///
/// The rectangle a shape fills is not always the frame. A blob is drawn
/// wherever its primitives put it, and its quad (the rectangle the panel
/// covers, which the renderer computes) is the outline's bounding box plus the
/// glow's halo; ``GlassPanel/shapeBounds`` reports it. A frame is only the
/// layout rectangle the blob's coordinates are relative to.
///
/// **Normalization rule** (the ``GlassParameters`` rule). A NaN or infinite
/// value anywhere is rejected with ``GlassParameterError/nonFiniteShape(_:)``
/// naming its ``Field``; finite values out of range are clamped. For a
/// blob the lengths that other effects clamp to half the shorter side (the
/// bezel, the rim, the light's reach) are clamped to the blob's inscribed
/// radius instead.
public enum GlassShape: Hashable, Sendable {
    /// The panel's frame with ``GlassParameters/cornerRadius`` (the original
    /// shape, and the default).
    case roundedRectangle
    /// The ellipse inscribed in the frame.
    case ellipse
    /// The superellipse inscribed in the frame; `exponent` is clamped to
    /// 2...10.
    case superellipse(exponent: Double)
    /// A smooth union of primitives.
    case blob(GlassBlob)

    /// A shape parameter that held a rejected value; see
    /// ``GlassParameterError/nonFiniteShape(_:)``.
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case superellipseExponent
        case primitiveX, primitiveY, primitiveRadius
        case primitiveHalfWidth, primitiveHalfHeight, primitiveCornerRadius, primitiveRotation
        case smoothness
        case wobbleAmplitude, wobbleSpeed, wobbleTimeOffset
    }

    /// The most primitives one blob uses; further ones are dropped.
    public static let maximumPrimitives = 6
    /// The superellipse exponents that are used.
    public static let superellipseExponents: ClosedRange<Double> = 2...10

    /// The familiar squircle: the superellipse of exponent 4.
    public static let squircle = GlassShape.superellipse(exponent: 4)

    /// Whether the outline changes with time (a blob's wobble). A host that
    /// does not run the effect clock for it moves ``GlassBlob/Wobble/timeOffset``
    /// itself, as it does for ``GlassLight``.
    public var isAnimated: Bool {
        if case let .blob(blob) = self { return blob.wobble.isAnimated }
        return false
    }
}

/// A smooth blob outline (GW-26): the polynomial smooth union of up to
/// ``GlassShape/maximumPrimitives`` primitives, so two shapes that touch
/// grow a neck between them instead of a crease, like pebbles of glass that
/// are one piece. Experimental.
///
/// **Coordinates.** Every length is in *frame units*: the origin is the center
/// of the panel's frame, x to the right and y down, and 1 is half the frame's
/// shorter side. A blob therefore scales with its frame and a circle stays a
/// circle in any frame. Frame units are clamped to −4...4 for positions and
/// 0...4 for radii and half sizes.
///
/// | Property | Unit | Valid range | Default | Meaning |
/// | --- | --- | --- | --- | --- |
/// | ``primitives`` | ``Primitive`` | 1 to ``GlassShape/maximumPrimitives`` | — | The parts. An empty list becomes one circle of radius 1. |
/// | ``smoothness`` | frame units | 0...2 | 0.25 | How far apart two parts' outlines can be and still blend. 0 is a hard union. |
/// | ``wobble`` | ``Wobble`` | see ``Wobble`` | none | A slow organic movement of the outline. |
public struct GlassBlob: Hashable, Sendable {
    /// One part of a blob.
    public enum Primitive: Hashable, Sendable {
        /// A disc.
        case circle(center: CGPoint, radius: Double)
        /// A stadium: the points within `radius` of the segment.
        case capsule(from: CGPoint, to: CGPoint, radius: Double)
        /// A rounded rectangle turned by `rotation` degrees (clockwise on
        /// the screen). `cornerRadius` is clamped to the smaller half size.
        case box(center: CGPoint, halfSize: CGSize, cornerRadius: Double, rotation: Double)
    }

    /// A slow movement of the outline: three plane waves, whose phases loop
    /// exactly every ``GlassBlob/loopDuration`` seconds of wobble time, so a
    /// recording of one loop repeats without a jump.
    ///
    /// | Property | Unit | Valid range | Default | Meaning |
    /// | --- | --- | --- | --- | --- |
    /// | ``amplitude`` | frame units | 0...``maximumAmplitude`` | 0 | How far the outline moves in or out. 0 is no wobble. |
    /// | ``speed`` | multiple | 0...``maximumSpeed`` | 1 | How fast wobble time runs. 0 shows one still shape, which is what Reduce Motion gets. |
    /// | ``timeOffset`` | seconds | any finite value | 0 | Added to the renderer's effect time, to show a chosen moment or to drive the wobble from the app's own clock. |
    public struct Wobble: Hashable, Sendable {
        public var amplitude: Double
        public var speed: Double
        public var timeOffset: Double

        public static let maximumAmplitude = 0.1
        public static let maximumSpeed = 3.0
        /// No wobble.
        public static let none = Wobble(amplitude: 0)

        public init(amplitude: Double, speed: Double = 1, timeOffset: Double = 0) {
            self.amplitude = amplitude
            self.speed = speed
            self.timeOffset = timeOffset
        }

        /// Whether the outline moves: an amplitude and a speed above zero.
        public var isAnimated: Bool {
            amplitude > 0 && speed > 0
        }
    }

    /// The parts, in the order they are blended.
    public var primitives: [Primitive]
    /// The blend distance, in frame units, 0...2.
    public var smoothness: Double
    /// The wobble; ``Wobble/none`` for none.
    public var wobble: Wobble

    /// The wobble time, in seconds, after which the wobble repeats.
    public static let loopDuration = GlassInterior.loopDuration

    public init(primitives: [Primitive], smoothness: Double = 0.25, wobble: Wobble = .none) {
        self.primitives = primitives
        self.smoothness = smoothness
        self.wobble = wobble
    }
}

extension GlassPanel {
    /// The rectangle the panel's outline fits in, in points, in the
    /// coordinate space of ``frame``, after the normalization rule: the frame
    /// itself for a rounded rectangle, an ellipse or a superellipse; the
    /// bounding box of the outline, wobble included, for a blob. The renderer's
    /// quad is this rectangle grown by one pixel and the glow's halo.
    public var shapeBounds: CGRect {
        guard let panel = try? normalized(), let geometry = panel.parameters.shape.geometry(frameSize: panel.frame.size) else {
            return frame
        }
        let amplitude = panel.parameters.shape.wobbleAmplitude(frameSize: panel.frame.size)
        let half = geometry.boundsHalfSize + amplitude
        let center = SIMD2(Double(panel.frame.midX), Double(panel.frame.midY)) + geometry.boundsCenter
        return CGRect(x: center.x - half.x, y: center.y - half.y, width: half.x * 2, height: half.y * 2)
    }
}

// MARK: Normalization

extension GlassShape {
    /// Applies the normalization rule: rejects non-finite values and clamps
    /// finite ones into range.
    func normalized() throws(GlassParameterError) -> GlassShape {
        switch self {
        case .roundedRectangle, .ellipse:
            return self
        case let .superellipse(exponent):
            guard exponent.isFinite else { throw .nonFiniteShape(.superellipseExponent) }
            return .superellipse(exponent: min(max(exponent, Self.superellipseExponents.lowerBound), Self.superellipseExponents.upperBound))
        case let .blob(blob):
            return .blob(try blob.normalized())
        }
    }

    /// The most a length (the bezel, a rim, a reach) may be, in points: half
    /// the shorter side of the frame, or for a blob its inscribed radius.
    func maximumLength(frameSize: CGSize) -> Double {
        let half = min(Double(frameSize.width), Double(frameSize.height)) / 2
        guard case .blob = self, let geometry = geometry(frameSize: frameSize) else { return half }
        return geometry.inscribedRadius
    }

    /// The wobble's amplitude in points; 0 for any shape but a blob.
    func wobbleAmplitude(frameSize: CGSize) -> Double {
        guard case let .blob(blob) = self else { return 0 }
        return blob.wobble.amplitude * min(Double(frameSize.width), Double(frameSize.height)) / 2
    }
}

extension GlassBlob {
    func normalized() throws(GlassParameterError) -> GlassBlob {
        func finite(_ value: Double, _ field: GlassShape.Field) throws(GlassParameterError) -> Double {
            guard value.isFinite else { throw .nonFiniteShape(field) }
            return value
        }
        func position(_ value: Double, _ field: GlassShape.Field) throws(GlassParameterError) -> Double {
            min(max(try finite(value, field), -4), 4)
        }
        func length(_ value: Double, _ field: GlassShape.Field) throws(GlassParameterError) -> Double {
            min(max(try finite(value, field), 0), 4)
        }
        func point(_ value: CGPoint) throws(GlassParameterError) -> CGPoint {
            CGPoint(x: try position(Double(value.x), .primitiveX), y: try position(Double(value.y), .primitiveY))
        }
        var kept: [Primitive] = []
        for primitive in primitives {
            let checked: Primitive
            switch primitive {
            case let .circle(center, radius):
                checked = .circle(center: try point(center), radius: try length(radius, .primitiveRadius))
            case let .capsule(from, to, radius):
                checked = .capsule(from: try point(from), to: try point(to), radius: try length(radius, .primitiveRadius))
            case let .box(center, halfSize, cornerRadius, rotation):
                let half = CGSize(
                    width: try length(Double(halfSize.width), .primitiveHalfWidth),
                    height: try length(Double(halfSize.height), .primitiveHalfHeight)
                )
                let corner = min(try length(cornerRadius, .primitiveCornerRadius), min(half.width, half.height))
                let turn = GlassGlow.reducedAngle(try finite(rotation, .primitiveRotation))
                checked = .box(center: try point(center), halfSize: half, cornerRadius: corner, rotation: turn)
            }
            if kept.count < GlassShape.maximumPrimitives {
                kept.append(checked)
            }
        }
        let blend = min(max(try finite(smoothness, .smoothness), 0), 2)
        let movement = Wobble(
            amplitude: min(max(try finite(wobble.amplitude, .wobbleAmplitude), 0), Wobble.maximumAmplitude),
            speed: min(max(try finite(wobble.speed, .wobbleSpeed), 0), Wobble.maximumSpeed),
            timeOffset: try finite(wobble.timeOffset, .wobbleTimeOffset)
        )
        if kept.isEmpty {
            kept = [.circle(center: .zero, radius: 1)]
        }
        return GlassBlob(primitives: kept, smoothness: blend, wobble: movement)
    }
}

// MARK: The CPU shape fields

/// The first-order distance and its gradient of one shape at a point, before
/// the renormalization the shader applies.
struct GlassShapeRaw: Equatable {
    var distance: Double
    var gradient: SIMD2<Double>

    /// The signed distance renormalized by the gradient length (at least 0.3),
    /// at most `inscribed` deep, and the unit outward normal: the shader's
    /// `gw_shape_field`.
    func sample(inscribed: Double) -> (distance: Double, normal: SIMD2<Double>) {
        let length = (gradient.x * gradient.x + gradient.y * gradient.y).squareRoot()
        // The renormalization fades out deeper than 35 % of the inscribed
        // radius (see `gw_shape_field`).
        let deep = min(max(-distance / max(0.35 * inscribed, 1), 0), 1)
        let scale = max(length, 0.3) * (1 - deep) + deep
        return (max(distance / scale, -inscribed), gradient / max(length, 1e-4))
    }
}

/// The ellipse inscribed in a rectangle, as the optics see it
/// (``GlassShapeField``). Mirrors `gw_shape_ellipse`.
package struct EllipseField: GlassShapeField, Equatable {
    package var center: SIMD2<Double>
    package var radii: SIMD2<Double>

    package var inscribedRadius: Double { min(radii.x, radii.y) }

    static func raw(_ q: SIMD2<Double>, radii: SIMD2<Double>) -> GlassShapeRaw {
        let n = q / (radii * radii)
        let k1 = (n.x * n.x + n.y * n.y).squareRoot()
        let p = q / radii
        let k0 = (p.x * p.x + p.y * p.y).squareRoot()
        guard k1 > 1e-6 else { return GlassShapeRaw(distance: -min(radii.x, radii.y), gradient: SIMD2(0, -1)) }
        return GlassShapeRaw(distance: k0 * (k0 - 1) / k1, gradient: n / k1)
    }

    package func signedDistance(at pixel: SIMD2<Double>) -> Double {
        Self.raw(pixel - center, radii: radii).sample(inscribed: inscribedRadius).distance
    }

    package func outwardNormal(at pixel: SIMD2<Double>) -> SIMD2<Double> {
        Self.raw(pixel - center, radii: radii).sample(inscribed: inscribedRadius).normal
    }

    package func lensDepth(at pixel: SIMD2<Double>) -> Double {
        max(-signedDistance(at: pixel), 0)
    }
}

/// The superellipse inscribed in a rectangle (``GlassShapeField``). Mirrors
/// `gw_shape_superellipse`.
package struct SuperellipseField: GlassShapeField, Equatable {
    package var center: SIMD2<Double>
    package var radii: SIMD2<Double>
    package var exponent: Double

    package var inscribedRadius: Double { min(radii.x, radii.y) }

    static func raw(_ q: SIMD2<Double>, radii: SIMD2<Double>, exponent n: Double) -> GlassShapeRaw {
        let a = SIMD2(max(abs(q.x) / radii.x, 1e-6), max(abs(q.y) / radii.y, 1e-6))
        let k0 = Foundation.pow(Foundation.pow(a.x, n) + Foundation.pow(a.y, n), 1 / n)
        let denominator = Foundation.pow(max(k0, 1e-6), n - 1)
        let slope = SIMD2(Foundation.pow(a.x, n - 1) / radii.x / denominator, Foundation.pow(a.y, n - 1) / radii.y / denominator)
        let length = (slope.x * slope.x + slope.y * slope.y).squareRoot()
        guard abs(q.x) + abs(q.y) >= 1e-4, length >= 1e-6 else {
            return GlassShapeRaw(distance: -min(radii.x, radii.y), gradient: SIMD2(0, -1))
        }
        return GlassShapeRaw(
            distance: (k0 - 1) / length,
            gradient: SIMD2(q.x >= 0 ? 1 : -1, q.y >= 0 ? 1 : -1) * slope / length
        )
    }

    package func signedDistance(at pixel: SIMD2<Double>) -> Double {
        Self.raw(pixel - center, radii: radii, exponent: exponent).sample(inscribed: inscribedRadius).distance
    }

    package func outwardNormal(at pixel: SIMD2<Double>) -> SIMD2<Double> {
        Self.raw(pixel - center, radii: radii, exponent: exponent).sample(inscribed: inscribedRadius).normal
    }

    package func lensDepth(at pixel: SIMD2<Double>) -> Double {
        max(-signedDistance(at: pixel), 0)
    }
}

/// One part of a blob in pixels (or points) from the field's center.
struct BlobPrimitive: Equatable {
    enum Kind: UInt32 {
        case circle = 0
        case capsule = 1
        case box = 2
    }

    var kind: Kind
    /// The circle's or the box's center, or the capsule's first end.
    var a: SIMD2<Double>
    /// The capsule's second end, or the box's half size.
    var b: SIMD2<Double>
    /// The circle's or the capsule's radius, or the box's corner radius.
    var radius: Double
    /// The box's rotation in radians.
    var rotation: Double

    /// The part in `unit`s per frame unit (points or pixels per half the
    /// frame's shorter side).
    init(_ primitive: GlassBlob.Primitive, unit: Double) {
        func vector(_ point: CGPoint) -> SIMD2<Double> { SIMD2(Double(point.x), Double(point.y)) * unit }
        switch primitive {
        case let .circle(center, radius):
            self.init(kind: .circle, a: vector(center), b: .zero, radius: radius * unit, rotation: 0)
        case let .capsule(from, to, radius):
            self.init(kind: .capsule, a: vector(from), b: vector(to), radius: radius * unit, rotation: 0)
        case let .box(center, halfSize, cornerRadius, rotation):
            self.init(
                kind: .box, a: vector(center), b: SIMD2(Double(halfSize.width), Double(halfSize.height)) * unit,
                radius: cornerRadius * unit, rotation: rotation * .pi / 180
            )
        }
    }

    init(kind: Kind, a: SIMD2<Double>, b: SIMD2<Double>, radius: Double, rotation: Double) {
        self.kind = kind
        self.a = a
        self.b = b
        self.radius = radius
        self.rotation = rotation
    }

    func translated(by offset: SIMD2<Double>) -> BlobPrimitive {
        var moved = self
        moved.a -= offset
        if kind == .capsule { moved.b -= offset }
        return moved
    }

    func scaled(by factor: Double) -> BlobPrimitive {
        BlobPrimitive(kind: kind, a: a * factor, b: b * factor, radius: radius * factor, rotation: rotation)
    }

    /// The part's axis-aligned extent: exact for a circle or a capsule, the
    /// turned box's for a box.
    var extent: (low: SIMD2<Double>, high: SIMD2<Double>) {
        switch kind {
        case .circle:
            return (a - radius, a + radius)
        case .capsule:
            return (SIMD2(min(a.x, b.x), min(a.y, b.y)) - radius, SIMD2(max(a.x, b.x), max(a.y, b.y)) + radius)
        case .box:
            let c = abs(cos(rotation)), s = abs(sin(rotation))
            let reach = SIMD2(c * b.x + s * b.y, s * b.x + c * b.y)
            return (a - reach, a + reach)
        }
    }

    /// Distance and gradient at `q`: mirrors `gw_shape_primitive`.
    func raw(_ q: SIMD2<Double>) -> GlassShapeRaw {
        func length(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }
        switch kind {
        case .circle:
            let offset = q - a
            let l = length(offset)
            return GlassShapeRaw(distance: l - radius, gradient: l > 1e-4 ? offset / l : SIMD2(0, -1))
        case .capsule:
            let axis = b - a
            let offset = q - a
            let h = min(max((offset.x * axis.x + offset.y * axis.y) / max(axis.x * axis.x + axis.y * axis.y, 1e-6), 0), 1)
            let away = offset - axis * h
            let l = length(away)
            var across = SIMD2(axis.y, -axis.x) + SIMD2(1e-6, 0)
            across /= length(across)
            return GlassShapeRaw(distance: l - radius, gradient: l > 1e-4 ? away / l : across)
        case .box:
            let offset = q - a
            let c = cos(rotation), s = sin(rotation)
            let local = SIMD2(c * offset.x + s * offset.y, -s * offset.x + c * offset.y)
            let d = SIMD2(abs(local.x), abs(local.y)) - (b - radius)
            let outside = SIMD2(max(d.x, 0), max(d.y, 0))
            let distance = length(outside) + min(max(d.x, d.y), 0) - radius
            let signs = SIMD2<Double>(local.x >= 0 ? 1 : -1, local.y >= 0 ? 1 : -1)
            var normal: SIMD2<Double>
            if d.x > 0, d.y > 0 {
                normal = d / length(d) * signs
            } else if d.x > d.y {
                normal = SIMD2(signs.x, 0)
            } else {
                normal = SIMD2(0, signs.y)
            }
            normal = SIMD2(c * normal.x - s * normal.y, s * normal.x + c * normal.y)
            return GlassShapeRaw(distance: distance, gradient: normal)
        }
    }
}

/// The smooth union of a blob's primitives, without the wobble (the CPU
/// reference of the outline at rest; the wobble is the shader's). Mirrors
/// `gw_shape_blob`.
package struct BlobField: GlassShapeField, Equatable {
    package var center: SIMD2<Double>
    var primitives: [BlobPrimitive]
    /// The smooth-union blend distance `k`.
    package var smoothness: Double
    package var inscribedRadius: Double

    /// The raw smooth-union distance (1-Lipschitz, so `-distance` never
    /// exceeds the true depth) and gradient at `q` from the field's center.
    func raw(_ q: SIMD2<Double>) -> GlassShapeRaw {
        var field = primitives[0].raw(q)
        for primitive in primitives.dropFirst() {
            field = Self.union(field, primitive.raw(q), k: smoothness)
        }
        return field
    }

    /// The polynomial smooth minimum with the blended gradient.
    static func union(_ a: GlassShapeRaw, _ b: GlassShapeRaw, k: Double) -> GlassShapeRaw {
        let h = max(k - abs(a.distance - b.distance), 0) / max(k, 1e-4)
        let first = a.distance < b.distance
        let near = first ? a.gradient : b.gradient
        let far = first ? b.gradient : a.gradient
        return GlassShapeRaw(
            distance: (first ? a.distance : b.distance) - h * h * k * 0.25,
            gradient: near * (1 - 0.5 * h) + far * (0.5 * h)
        )
    }

    package func signedDistance(at pixel: SIMD2<Double>) -> Double {
        raw(pixel - center).sample(inscribed: inscribedRadius).distance
    }

    package func outwardNormal(at pixel: SIMD2<Double>) -> SIMD2<Double> {
        raw(pixel - center).sample(inscribed: inscribedRadius).normal
    }

    package func lensDepth(at pixel: SIMD2<Double>) -> Double {
        max(-signedDistance(at: pixel), 0)
    }
}

// MARK: Resolving a shape for a frame

/// A freeform shape resolved for one frame size, in points, relative to the
/// frame's center. Equal for equal shapes and sizes, so it is cached.
struct GlassShapeGeometry: Equatable {
    enum Kind: Equatable {
        case ellipse
        case superellipse(exponent: Double)
        /// Primitives relative to the bounds' center, in points.
        case blob(primitives: [BlobPrimitive], smoothness: Double)
    }

    var kind: Kind
    /// The outline's bounding box center, relative to the frame's center.
    var boundsCenter: SIMD2<Double>
    var boundsHalfSize: SIMD2<Double>
    /// A lower bound of the largest inscribed circle's radius.
    var inscribedRadius: Double
}

extension GlassShape {
    /// The shape resolved for a frame of `frameSize` points, or `nil` for the
    /// rounded rectangle. The shape must be normalized. A blob's bounds and
    /// inscribed radius are sampled once and cached.
    func geometry(frameSize: CGSize) -> GlassShapeGeometry? {
        let half = SIMD2(Double(frameSize.width), Double(frameSize.height)) / 2
        switch self {
        case .roundedRectangle:
            return nil
        case .ellipse:
            return GlassShapeGeometry(kind: .ellipse, boundsCenter: .zero, boundsHalfSize: half, inscribedRadius: min(half.x, half.y))
        case let .superellipse(exponent):
            return GlassShapeGeometry(
                kind: .superellipse(exponent: exponent), boundsCenter: .zero, boundsHalfSize: half,
                inscribedRadius: min(half.x, half.y)
            )
        case let .blob(blob):
            return GlassShapeCache.shared.geometry(for: blob, frameSize: frameSize)
        }
    }
}

/// Resolved blobs by shape and frame size: the sampling that finds a blob's
/// bounds and inscribed radius runs once, not once per draw.
final class GlassShapeCache: @unchecked Sendable {
    static let shared = GlassShapeCache()

    private struct Key: Hashable {
        var blob: GlassBlob
        var width: Double
        var height: Double
    }

    private let lock = NSLock()
    private var entries: [Key: GlassShapeGeometry] = [:]
    private static let capacity = 64

    func geometry(for blob: GlassBlob, frameSize: CGSize) -> GlassShapeGeometry {
        // The wobble does not change the resting outline.
        var resting = blob
        resting.wobble = .none
        let key = Key(blob: resting, width: Double(frameSize.width), height: Double(frameSize.height))
        lock.lock()
        let cached = entries[key]
        lock.unlock()
        if let cached { return cached }
        let resolved = Self.resolve(blob, frameSize: frameSize)
        lock.lock()
        if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
        entries[key] = resolved
        lock.unlock()
        return resolved
    }

    /// Finds the bounds and the inscribed radius by sampling the resting
    /// field. The bounds are the union of the primitives' own extents (always
    /// inside the blob) and the sampled extent of the blob grown by the
    /// largest bulge a smooth union can add, `(n − 1) k / 4`, with a margin of
    /// 1.5 cells; so a bulge between primitives is inside the quad.
    static func resolve(_ blob: GlassBlob, frameSize: CGSize) -> GlassShapeGeometry {
        let unit = min(Double(frameSize.width), Double(frameSize.height)) / 2
        let primitives = blob.primitives.map { BlobPrimitive($0, unit: unit) }
        let k = blob.smoothness * unit
        var low = SIMD2(Double.infinity, Double.infinity), high = SIMD2(-Double.infinity, -Double.infinity)
        for primitive in primitives {
            let extent = primitive.extent
            low = pointwiseMin(low, extent.low)
            high = pointwiseMax(high, extent.high)
        }
        let grow = Double(max(primitives.count - 1, 0)) * k / 4
        let outerLow = low - grow, outerHigh = high + grow
        let field = BlobField(center: .zero, primitives: primitives, smoothness: k, inscribedRadius: 0)
        let steps = 48
        let cell = (outerHigh - outerLow) / Double(steps)
        var sampledLow = low, sampledHigh = high
        var deepest = 0.0, deepestAt = (low + high) / 2
        for row in 0...steps {
            for column in 0...steps {
                let point = outerLow + SIMD2(Double(column), Double(row)) * cell
                let d = field.raw(point).distance
                if d <= 0 {
                    sampledLow = pointwiseMin(sampledLow, point - cell * 1.5)
                    sampledHigh = pointwiseMax(sampledHigh, point + cell * 1.5)
                    if d < deepest {
                        deepest = d
                        deepestAt = point
                    }
                }
            }
        }
        // Refine the deepest point on a finer grid around it.
        let fine = 16
        for row in -fine...fine {
            for column in -fine...fine {
                let point = deepestAt + SIMD2(Double(column), Double(row)) * (cell / Double(fine))
                deepest = min(deepest, field.raw(point).distance)
            }
        }
        low = pointwiseMax(sampledLow, outerLow)
        high = pointwiseMin(sampledHigh, outerHigh)
        let center = (low + high) / 2
        let moved = primitives.map { $0.translated(by: center) }
        return GlassShapeGeometry(
            kind: .blob(primitives: moved, smoothness: k),
            boundsCenter: center, boundsHalfSize: (high - low) / 2,
            inscribedRadius: max(-deepest, 0)
        )
    }
}

private func pointwiseMin(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SIMD2<Double> {
    SIMD2(min(a.x, b.x), min(a.y, b.y))
}

private func pointwiseMax(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SIMD2<Double> {
    SIMD2(max(a.x, b.x), max(a.y, b.y))
}

/// A freeform shape in target pixels for one draw: its field, the bounding
/// box the panel's quad covers, and the uploaded record. The rounded
/// rectangle has no model.
struct GlassShapeModel: Equatable {
    var field: Field
    /// The bounding box center and half size in target pixels, wobble
    /// included.
    var center: SIMD2<Double>
    var halfSize: SIMD2<Double>
    var inscribedRadius: Double
    var record: GWShapeUniforms

    enum Field: Equatable {
        case ellipse(EllipseField)
        case superellipse(SuperellipseField)
        case blob(BlobField)
    }

    static func == (lhs: GlassShapeModel, rhs: GlassShapeModel) -> Bool {
        lhs.field == rhs.field && lhs.center == rhs.center && lhs.halfSize == rhs.halfSize
            && lhs.inscribedRadius == rhs.inscribedRadius
            && withUnsafeBytes(of: lhs.record) { Array($0) } == withUnsafeBytes(of: rhs.record) { Array($0) }
    }

    /// The wavelength of the wobble's waves, in frame units.
    static let wobbleWavelength = 1.6
    /// The wobble waves' time multipliers: whole turns per loop.
    static let wobbleTurns = SIMD3<Double>(6, 9, 13)
    /// The wobble waves' phases at wobble time zero.
    static let wobblePhaseOffsets = SIMD3<Double>(0, 2.1, 4.2)

    /// Resolves a normalized shape for a panel frame, or returns `nil` for the
    /// rounded rectangle.
    init?(_ shape: GlassShape, frame: CGRect, displayScale: Double, effectTime: Double) {
        guard let geometry = shape.geometry(frameSize: frame.size) else { return nil }
        let unit = min(Double(frame.width), Double(frame.height)) / 2 * displayScale
        let amplitude = shape.wobbleAmplitude(frameSize: frame.size) * displayScale
        let frameCenter = SIMD2(Double(frame.midX), Double(frame.midY)) * displayScale
        center = frameCenter + geometry.boundsCenter * displayScale
        halfSize = geometry.boundsHalfSize * displayScale + amplitude
        inscribedRadius = geometry.inscribedRadius * displayScale
        var record = GWShapeUniforms()
        record.inscribedRadius = Float(inscribedRadius)
        let radii = geometry.boundsHalfSize * displayScale
        switch geometry.kind {
        case .ellipse:
            field = .ellipse(EllipseField(center: center, radii: radii))
            record.kind = GWShapeKindEllipse.rawValue
        case let .superellipse(exponent):
            field = .superellipse(SuperellipseField(center: center, radii: radii, exponent: exponent))
            record.kind = GWShapeKindSuperellipse.rawValue
            record.exponent = Float(exponent)
        case let .blob(primitives, smoothness):
            let scaled = primitives.map { $0.scaled(by: displayScale) }
            field = .blob(BlobField(center: center, primitives: scaled, smoothness: smoothness * displayScale, inscribedRadius: inscribedRadius))
            record.kind = GWShapeKindBlob.rawValue
            record.primitiveCount = UInt32(scaled.count)
            record.smoothness = Float(smoothness * displayScale)
            withUnsafeMutableBytes(of: &record.primitives) { raw in
                let primitiveRecords = raw.bindMemory(to: GWShapePrimitive.self)
                for (index, primitive) in scaled.enumerated() {
                    primitiveRecords[index] = Self.record(primitive)
                }
            }
            if case let .blob(blob) = shape, blob.wobble.amplitude > 0 {
                record.wobbleAmplitude = Float(amplitude)
                record.wobbleWavelength = Float(Self.wobbleWavelength * unit)
                record.wobblePhases = SIMD4<Float>(SIMD3<Float>(Self.wobblePhases(blob.wobble, effectTime: effectTime)), 0)
            }
        }
        self.record = record
    }

    /// The wobble's three phases in radians at an effect time: whole turns per
    /// loop, so time `loopDuration` seconds later gives the same phases.
    static func wobblePhases(_ wobble: GlassBlob.Wobble, effectTime: Double) -> SIMD3<Double> {
        let loop = GlassBlob.loopDuration
        var time = ((effectTime + wobble.timeOffset) * wobble.speed).truncatingRemainder(dividingBy: loop)
        if time < 0 { time += loop }
        return wobblePhaseOffsets + wobbleTurns * (2 * Double.pi * time / loop)
    }

    private static func record(_ primitive: BlobPrimitive) -> GWShapePrimitive {
        var record = GWShapePrimitive()
        record.kind = primitive.kind.rawValue
        switch primitive.kind {
        case .circle:
            record.geometry = SIMD4<Float>(Float(primitive.a.x), Float(primitive.a.y), Float(primitive.radius), 0)
        case .capsule:
            record.geometry = SIMD4<Float>(Float(primitive.a.x), Float(primitive.a.y), Float(primitive.b.x), Float(primitive.b.y))
            record.shape = SIMD4<Float>(Float(primitive.radius), 0, 0, 0)
        case .box:
            record.geometry = SIMD4<Float>(Float(primitive.a.x), Float(primitive.a.y), Float(primitive.b.x), Float(primitive.b.y))
            record.shape = SIMD4<Float>(Float(primitive.radius), Float(cos(primitive.rotation)), Float(sin(primitive.rotation)), 0)
        }
        return record
    }

    private var resolvedField: any GlassShapeField {
        switch field {
        case let .ellipse(field): field
        case let .superellipse(field): field
        case let .blob(field): field
        }
    }

    func signedDistance(at pixel: SIMD2<Double>) -> Double {
        resolvedField.signedDistance(at: pixel)
    }

    func outwardNormal(at pixel: SIMD2<Double>) -> SIMD2<Double> {
        resolvedField.outwardNormal(at: pixel)
    }
}
