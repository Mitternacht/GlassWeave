import CoreGraphics
import Foundation

/// Two of GlassWeave's own glass surfaces that merge into one and separate
/// again under a deterministic progress (GW-13).
///
/// > Important: Experimental. This API may change before a stable release.
///
/// **Custom to custom.** GlassWeave owns both surfaces: they are two parts of
/// one ``GlassShape/blob(_:)``, drawn as **one** panel, so the lens, the
/// dispersion, the light, the frost, the glow, the liquid and the shadow all
/// follow the merged outline and there is no seam at the join. Apple's
/// `UIGlassEffect` merges through the system's glass container
/// (`UIGlassContainerEffect`); that is a separate material system, and
/// nothing here touches it.
///
/// Each surface is a ``Pose`` at progress 0 (``Surface/separate``) and another
/// at progress 1 (``Surface/merged``): a circle or a capsule in frame units
/// (see ``GlassBlob``). ``blob(progress:)`` blends the poses linearly and
/// joins the two surfaces with the blob's polynomial smooth union, whose
/// blend distance is ``smoothness(at:)``: 0 when the surfaces are far apart,
/// the most (``smoothness``) while the gap between them closes, back to 0 once
/// they overlap (at ``neckEnd``), so the pill they end as has no swelling where
/// the two overlap and its outline is exact. The result is a normal ``GlassBlob`` (at most two primitives), so
/// nothing in the shader or in the renderer changes: a merge is a blob that
/// the app moves, and ``GlassParameters/shape`` takes it as it takes any
/// other.
///
/// ```swift
/// // Two round buttons 120 pt apart in a 240 x 64 pt frame, which merge
/// // into one pill when each one reaches for the other.
/// let size = CGSize(width: 240, height: 64)
/// let left = GlassSurfaceMerge.Pose.circle(center: CGPoint(x: -60, y: 0), radius: 32, in: size)
/// let right = GlassSurfaceMerge.Pose.circle(center: CGPoint(x: 60, y: 0), radius: 32, in: size)
/// let pill = GlassSurfaceMerge.Pose.capsule(from: CGPoint(x: -60, y: 0), to: CGPoint(x: 60, y: 0), radius: 32, in: size)
/// let merge = GlassSurfaceMerge(
///     first: .init(separate: left, merged: pill), second: .init(separate: right, merged: pill)
/// )
/// parameters.shape = try merge.shape(progress: 0.5)
/// ```
///
/// **Normalization rule** (the ``GlassParameters`` rule). A NaN or infinite
/// progress throws ``GlassParameterError/nonFiniteShape(_:)`` naming
/// ``GlassShape/Field/mergeProgress``; a finite one is clamped to 0...1. The
/// other values (positions, radii, ``smoothness``) follow the blob's rule
/// when the shape is set on a panel.
///
/// | Property | Unit | Valid range | Default | Meaning |
/// | --- | --- | --- | --- | --- |
/// | ``first``, ``second`` | ``Surface`` | positions −4...4, radii 0...4 (frame units) | — | The two surfaces, each with a separate and a merged pose. |
/// | ``smoothness`` | frame units | 0...2 | 0.5 | The neck's blend distance at its widest (the outline). |
/// | ``interiorSmoothness`` | frame units | 0...2 | 0.9 | The same for the inside, so the lens shows no crease along the join. |
/// | ``neckEnd`` | progress | 0.2...1 | 0.8 | The progress at which the neck's blend has faded to 0; it is widest at half of it. |
public struct GlassSurfaceMerge: Hashable, Sendable {
    /// One surface at one moment: the stadium of points within ``radius`` of
    /// the segment from ``from`` to ``to`` (a circle when they are equal), in
    /// frame units: the origin is the center of the panel's frame, x to the
    /// right and y down, and 1 is half the frame's shorter side.
    public struct Pose: Hashable, Sendable {
        public var from: CGPoint
        public var to: CGPoint
        public var radius: Double

        public init(from: CGPoint, to: CGPoint, radius: Double) {
            self.from = from
            self.to = to
            self.radius = radius
        }

        /// A disc, in frame units.
        public static func circle(center: CGPoint, radius: Double) -> Pose {
            Pose(from: center, to: center, radius: radius)
        }

        /// A stadium, in frame units.
        public static func capsule(from: CGPoint, to: CGPoint, radius: Double) -> Pose {
            Pose(from: from, to: to, radius: radius)
        }

        /// A disc given in points from the center of a frame of `frameSize`.
        public static func circle(center: CGPoint, radius: Double, in frameSize: CGSize) -> Pose {
            capsule(from: center, to: center, radius: radius, in: frameSize)
        }

        /// A stadium given in points from the center of a frame of `frameSize`.
        public static func capsule(from: CGPoint, to: CGPoint, radius: Double, in frameSize: CGSize) -> Pose {
            let unit = Double(min(frameSize.width, frameSize.height)) / 2
            guard unit > 0 else { return Pose(from: from, to: to, radius: radius) }
            return Pose(
                from: CGPoint(x: Double(from.x) / unit, y: Double(from.y) / unit),
                to: CGPoint(x: Double(to.x) / unit, y: Double(to.y) / unit),
                radius: radius / unit
            )
        }

        func blended(to other: Pose, _ t: Double) -> Pose {
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * CGFloat(t) }
            return Pose(
                from: CGPoint(x: mix(from.x, other.from.x), y: mix(from.y, other.from.y)),
                to: CGPoint(x: mix(to.x, other.to.x), y: mix(to.y, other.to.y)),
                radius: radius + (other.radius - radius) * t
            )
        }

        var primitive: GlassBlob.Primitive {
            from == to ? .circle(center: from, radius: radius) : .capsule(from: from, to: to, radius: radius)
        }
    }

    /// One of the two surfaces: where it is apart and where it is merged.
    public struct Surface: Hashable, Sendable {
        /// The pose at progress 0.
        public var separate: Pose
        /// The pose at progress 1. Give both surfaces the same merged pose to
        /// end as one clean outline.
        public var merged: Pose

        public init(separate: Pose, merged: Pose) {
            self.separate = separate
            self.merged = merged
        }
    }

    /// The first surface; it is drawn first in the blend.
    public var first: Surface
    /// The second surface.
    public var second: Surface
    /// The neck's blend distance at its widest, in frame units, 0...2. At 0
    /// the surfaces join with a crease, as a hard union.
    public var smoothness: Double
    /// The blend distance of the blob's *interior* at its widest, in frame
    /// units, 0...2 (``GlassBlob/interiorSmoothness``): it rounds the crease
    /// that the lens depth and the normals would show along the line where the
    /// two surfaces overlap, which the narrower outline blend cannot hide
    /// without swelling the outline. It follows the same curve as
    /// ``smoothness``. 0 leaves the interior as the plain union.
    public var interiorSmoothness: Double
    /// The progress, 0.2...1, at which the blend has faded to 0 and the two
    /// surfaces are simply overlapping shapes. Past it the union adds no
    /// swelling, so the merged pill is exact; before it the neck forms and
    /// fills. Choose it where the surfaces overlap enough that no notch is left.
    public var neckEnd: Double

    /// The default ``smoothness``: a soft neck that is clean, not gooey.
    public static let defaultSmoothness = 0.5
    /// The default ``interiorSmoothness``.
    public static let defaultInteriorSmoothness = 0.9

    public init(
        first: Surface, second: Surface, smoothness: Double = GlassSurfaceMerge.defaultSmoothness,
        interiorSmoothness: Double = GlassSurfaceMerge.defaultInteriorSmoothness, neckEnd: Double = 0.8
    ) {
        self.first = first
        self.second = second
        self.smoothness = smoothness
        self.interiorSmoothness = interiorSmoothness
        self.neckEnd = neckEnd
    }

    /// `progress` as the rule says: a finite value is clamped to 0...1, a NaN
    /// or infinite one throws.
    public static func normalizedProgress(_ progress: Double) throws(GlassParameterError) -> Double {
        guard progress.isFinite else { throw .nonFiniteShape(.mergeProgress) }
        return min(max(progress, 0), 1)
    }

    /// The blend distance at `progress` (0...1, clamped), in frame units:
    /// ``smoothness`` x sin²(π t) for t = progress / ``neckEnd`` (at most 1),
    /// so it is 0 at the start (two exact shapes), widest at half of
    /// ``neckEnd`` while the neck forms, and 0 again from ``neckEnd`` on (the
    /// exact merged outline).
    public func smoothness(at progress: Double) -> Double {
        smoothness * neckWeight(at: progress)
    }

    /// The shared curve of both blends, 0...1.
    func neckWeight(at progress: Double) -> Double {
        let p = min(max(progress.isFinite ? progress : 0, 0), 1)
        let end = min(max(neckEnd.isFinite ? neckEnd : 0.8, 0.2), 1)
        let s = sin(Double.pi * min(p / end, 1))
        return s * s
    }

    /// The two surfaces as one blob at `progress`. Deterministic: the same
    /// progress always gives the same blob.
    public func blob(progress: Double) throws(GlassParameterError) -> GlassBlob {
        let p = try Self.normalizedProgress(progress)
        let a = first.separate.blended(to: first.merged, p)
        let b = second.separate.blended(to: second.merged, p)
        return GlassBlob(
            primitives: [a.primitive, b.primitive], smoothness: smoothness(at: p),
            interiorSmoothness: interiorSmoothness * neckWeight(at: p)
        )
    }

    /// The merged outline at `progress` as a shape, ready for
    /// ``GlassParameters/shape``.
    public func shape(progress: Double) throws(GlassParameterError) -> GlassShape {
        .blob(try blob(progress: progress))
    }
}
