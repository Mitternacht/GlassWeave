import CoreGraphics
import Foundation

/// A value a proximity merge rejected: a NaN or infinite number, named by the
/// field that held it.
///
/// > Important: Experimental. This API may change before a stable release.
public enum GlassProximityMergeError: Error, Hashable, Sendable {
    /// The input that held a rejected value.
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case startGap, fullGap, release, blend, interiorBlend
        /// The distance between two outlines.
        case gap
        /// A coordinate, radius or size of an ``GlassProximityMerge/Outline``.
        case outline
    }

    /// A NaN or infinite value in `field`.
    case nonFinite(Field)
    /// The frame a blob is built in has no area.
    case emptyFrame
}

/// Two draggable glass panels that merge as they approach and separate when
/// they are pulled apart: the deterministic part (GW-32).
///
/// > Important: Experimental. This API may change before a stable release.
///
/// **The function.** ``progress(gap:isMerged:)`` maps the *gap* between two
/// outlines (points, 0 when they touch, negative when they overlap) to a merge
/// progress from 0 (two separate shapes) to 1 (one joined shape): a smooth
/// ramp that is 0 at and beyond ``startGap`` and 1 at and inside ``fullGap``.
/// It is a pure function: the same inputs always give the same progress; for a
/// given state it never decreases as the gap closes; it is clamped to 0...1.
///
/// **Hysteresis.** A pair that has already merged holds on to the join: its
/// ramp is shifted outward by ``release`` points. The state flips to merged
/// when the gap reaches ``fullGap`` and back to apart when the gap passes
/// ``startGap`` + ``release``, and both curves agree where the state flips, so
/// there is no jump of progress and no flicker when a finger hovers at a
/// threshold. The same gap therefore gives a different progress depending on
/// where the pair came from: the loop a pull-apart follows is not the loop of
/// the approach, as with the system's own merge.
///
/// | Property | Unit | Valid range | Default | Meaning |
/// | --- | --- | --- | --- | --- |
/// | ``startGap`` | points | 1...400 | 40 | The gap at which an approaching pair starts to merge. |
/// | ``fullGap`` | points | -100...(``startGap`` - 0.5) | 6 | The gap at which it is fully merged (and the state latches to merged). |
/// | ``release`` | points | 0...200 | 14 | How much further a merged pair is pulled before it lets go. 0 is no hysteresis. |
/// | ``blend`` | points | 0...400 | 56 | The blob's blend distance at progress 1: the neck's reach. |
/// | ``interiorBlend`` | points | 0...400 | 72 | The same for the inside (``GlassBlob/interiorSmoothness``), so the lens shows no crease along the join. |
///
/// **Normalization rule.** The throwing initializer rejects a NaN or infinite
/// value with ``GlassProximityMergeError/nonFinite(_:)`` naming the field and
/// clamps a finite one into its range.
///
/// **Shapes.** An ``Outline`` is a circle, a capsule or a rounded rectangle in
/// points. The merged shape is one ``GlassBlob`` of up to
/// ``GlassShape/maximumPrimitives`` parts (circles, capsules and the blob's
/// rounded-box primitive), drawn as **one** panel, so the lens, the light and
/// the shadow follow the joined outline with no seam. Nothing in the shader or
/// the renderer changes.
///
/// **Custom to custom.** Both panels are GlassWeave's own glass. Apple's
/// `UIGlassEffect` merges through `UIGlassContainerEffect`, a separate material
/// system that this does not touch.
public struct GlassProximityMerge: Hashable, Sendable {
    public let startGap: Double
    public let fullGap: Double
    public let release: Double
    public let blend: Double
    public let interiorBlend: Double

    /// The defaults of the table above: a calm, clean join.
    public static let standard = GlassProximityMerge(
        startGap: 40, fullGap: 6, release: 14, blend: 56, interiorBlend: 72, checked: ()
    )

    /// Creates a merge, applying the normalization rule.
    public init(
        startGap: Double = 40, fullGap: Double = 6, release: Double = 14, blend: Double = 56, interiorBlend: Double = 72
    ) throws(GlassProximityMergeError) {
        func finite(_ value: Double, _ field: GlassProximityMergeError.Field) throws(GlassProximityMergeError) -> Double {
            guard value.isFinite else { throw .nonFinite(field) }
            return value
        }
        let start = min(max(try finite(startGap, .startGap), 1), 400)
        let full = min(max(try finite(fullGap, .fullGap), -100), start - 0.5)
        self.init(
            startGap: start, fullGap: full,
            release: min(max(try finite(release, .release), 0), 200),
            blend: min(max(try finite(blend, .blend), 0), 400),
            interiorBlend: min(max(try finite(interiorBlend, .interiorBlend), 0), 400),
            checked: ()
        )
    }

    private init(startGap: Double, fullGap: Double, release: Double, blend: Double, interiorBlend: Double, checked: Void) {
        self.startGap = startGap
        self.fullGap = fullGap
        self.release = release
        self.blend = blend
        self.interiorBlend = interiorBlend
    }

    // MARK: The function

    /// The merge progress, 0...1, of a pair whose outlines are `gap` points
    /// apart, for a pair that is currently apart (`isMerged` false) or merged.
    /// A NaN or infinite gap throws.
    public func progress(gap: Double, isMerged: Bool) throws(GlassProximityMergeError) -> Double {
        guard gap.isFinite else { throw .nonFinite(.gap) }
        let shift = isMerged ? release : 0
        let t = min(max((startGap + shift - gap) / (startGap - fullGap), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The state after seeing `gap`: a pair latches to merged when the gap
    /// reaches ``fullGap`` and lets go when it passes ``startGap`` + ``release``;
    /// in between it keeps its state. A NaN or infinite gap throws.
    public func isMerged(afterGap gap: Double, wasMerged: Bool) throws(GlassProximityMergeError) -> Bool {
        guard gap.isFinite else { throw .nonFinite(.gap) }
        return wasMerged ? gap < startGap + release : gap <= fullGap
    }

    // MARK: Outlines

    /// One panel's outline in points, in any one coordinate space (the
    /// surface's, usually).
    public enum Outline: Hashable, Sendable {
        /// A disc.
        case circle(center: CGPoint, radius: Double)
        /// A stadium: the points within `radius` of the segment.
        case capsule(from: CGPoint, to: CGPoint, radius: Double)
        /// An axis-aligned rounded rectangle. `cornerRadius` is clamped to
        /// half of the shorter side.
        case roundedRectangle(frame: CGRect, cornerRadius: Double)

        /// The cheapest exact outline of a panel's `frame` with `cornerRadius`:
        /// a circle for a square frame whose corners are fully round, a
        /// capsule for a fully round long frame, a rounded rectangle
        /// otherwise.
        public static func panel(frame: CGRect, cornerRadius: Double) -> Outline {
            let rect = frame.standardized
            let half = Double(min(rect.width, rect.height)) / 2
            // A NaN or infinite value stays a rounded rectangle, which the gap
            // then rejects by name.
            guard cornerRadius.isFinite, half.isFinite, cornerRadius >= half - 0.001 else {
                return .roundedRectangle(frame: rect, cornerRadius: cornerRadius)
            }
            if rect.width > rect.height + 0.001 {
                return .capsule(
                    from: CGPoint(x: rect.minX + CGFloat(half), y: rect.midY),
                    to: CGPoint(x: rect.maxX - CGFloat(half), y: rect.midY), radius: half
                )
            }
            if rect.height > rect.width + 0.001 {
                return .capsule(
                    from: CGPoint(x: rect.midX, y: rect.minY + CGFloat(half)),
                    to: CGPoint(x: rect.midX, y: rect.maxY - CGFloat(half)), radius: half
                )
            }
            return .circle(center: CGPoint(x: rect.midX, y: rect.midY), radius: half)
        }

        /// The gap to `other`, in points: the distance between the two
        /// outlines (0 when they touch, negative when they overlap; once the
        /// cores overlap it stays at minus the sum of the radii). Exact:
        /// every outline is a convex core (a point, a segment or a rectangle)
        /// grown by its radius, so the gap is the distance between the cores
        /// less both radii. A NaN or infinite coordinate throws.
        public func gap(to other: Outline) throws(GlassProximityMergeError) -> Double {
            let a = try core(), b = try other.core()
            return a.distance(to: b) - a.radius - b.radius
        }

        fileprivate func core() throws(GlassProximityMergeError) -> Core {
            func finite(_ values: [Double]) throws(GlassProximityMergeError) {
                if values.contains(where: { !$0.isFinite }) { throw .nonFinite(.outline) }
            }
            switch self {
            case let .circle(center, radius):
                try finite([Double(center.x), Double(center.y), radius])
                return Core(points: [center], radius: max(radius, 0))
            case let .capsule(from, to, radius):
                try finite([Double(from.x), Double(from.y), Double(to.x), Double(to.y), radius])
                return Core(points: [from, to], radius: max(radius, 0))
            case let .roundedRectangle(frame, cornerRadius):
                let rect = frame.standardized
                try finite([Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height), cornerRadius])
                let r = min(max(cornerRadius, 0), Double(min(rect.width, rect.height)) / 2)
                let inset = rect.insetBy(dx: CGFloat(r), dy: CGFloat(r))
                let wide = inset.width > 0.001, tall = inset.height > 0.001
                switch (wide, tall) {
                case (false, false):
                    return Core(points: [CGPoint(x: rect.midX, y: rect.midY)], radius: r)
                case (false, true):
                    return Core(points: [CGPoint(x: rect.midX, y: inset.minY), CGPoint(x: rect.midX, y: inset.maxY)], radius: r)
                case (true, false):
                    return Core(points: [CGPoint(x: inset.minX, y: rect.midY), CGPoint(x: inset.maxX, y: rect.midY)], radius: r)
                case (true, true):
                    return Core(points: [
                        CGPoint(x: inset.minX, y: inset.minY), CGPoint(x: inset.maxX, y: inset.minY),
                        CGPoint(x: inset.maxX, y: inset.maxY), CGPoint(x: inset.minX, y: inset.maxY),
                    ], radius: r)
                }
            }
        }

        /// The blob primitive for this outline, in frame units: the origin is
        /// the center of `frame`, 1 is `unit` points.
        fileprivate func primitive(origin: CGPoint, unit: Double) -> GlassBlob.Primitive {
            func point(_ p: CGPoint) -> CGPoint {
                CGPoint(x: (Double(p.x) - Double(origin.x)) / unit, y: (Double(p.y) - Double(origin.y)) / unit)
            }
            switch self {
            case let .circle(center, radius):
                return .circle(center: point(center), radius: radius / unit)
            case let .capsule(from, to, radius):
                return .capsule(from: point(from), to: point(to), radius: radius / unit)
            case let .roundedRectangle(frame, cornerRadius):
                let rect = frame.standardized
                return .box(
                    center: point(CGPoint(x: rect.midX, y: rect.midY)),
                    halfSize: CGSize(width: Double(rect.width) / 2 / unit, height: Double(rect.height) / 2 / unit),
                    cornerRadius: cornerRadius / unit, rotation: 0
                )
            }
        }
    }

    /// A convex set that an outline is the Minkowski sum of with a disc: a
    /// point (1 vertex), a segment (2) or a rectangle (4, in order).
    fileprivate struct Core {
        var points: [CGPoint]
        var radius: Double

        private var edges: [(CGPoint, CGPoint)] {
            switch points.count {
            case 1: [(points[0], points[0])]
            case 2: [(points[0], points[1])]
            default: points.indices.map { (points[$0], points[($0 + 1) % points.count]) }
            }
        }

        func distance(to other: Core) -> Double {
            if contains(anyOf: other.points) || other.contains(anyOf: points) { return 0 }
            var best = Double.infinity
            for (a0, a1) in edges {
                for (b0, b1) in other.edges {
                    if Self.cross(a0, a1, b0, b1) { return 0 }
                    best = min(best, Self.distance(from: a0, toSegment: b0, b1), Self.distance(from: a1, toSegment: b0, b1))
                    best = min(best, Self.distance(from: b0, toSegment: a0, a1), Self.distance(from: b1, toSegment: a0, a1))
                }
            }
            return best
        }

        /// Whether any of `candidates` lies inside this rectangle (only a
        /// rectangle has an inside).
        private func contains(anyOf candidates: [CGPoint]) -> Bool {
            guard points.count == 4 else { return false }
            return candidates.contains { point in
                var positive = false, negative = false
                for (a, b) in edges {
                    let side = (Double(b.x) - Double(a.x)) * (Double(point.y) - Double(a.y))
                        - (Double(b.y) - Double(a.y)) * (Double(point.x) - Double(a.x))
                    if side > 0 { positive = true } else if side < 0 { negative = true }
                }
                return !(positive && negative)
            }
        }

        private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            let length2 = dx * dx + dy * dy
            var t = length2 > 1e-12 ? ((Double(p.x - a.x)) * dx + (Double(p.y - a.y)) * dy) / length2 : 0
            t = min(max(t, 0), 1)
            let ex = Double(a.x) + t * dx - Double(p.x), ey = Double(a.y) + t * dy - Double(p.y)
            return (ex * ex + ey * ey).squareRoot()
        }

        /// Whether two segments properly cross (touching ends count as
        /// distance 0 through the vertex distances instead).
        private static func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
            func orient(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> Double {
                (Double(q.x) - Double(p.x)) * (Double(r.y) - Double(p.y)) - (Double(q.y) - Double(p.y)) * (Double(r.x) - Double(p.x))
            }
            let d1 = orient(a, b, c), d2 = orient(a, b, d), d3 = orient(c, d, a), d4 = orient(c, d, b)
            return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
        }
    }

    // MARK: Groups of panels

    /// The state of one pair after the last ``Tracker/update(_:)``.
    public struct PairState: Hashable, Sendable {
        public var first: Int
        public var second: Int
        /// The gap, in points.
        public var gap: Double
        public var progress: Double
        public var isMerged: Bool
    }

    /// A set of panels that are drawn as one blob: the connected panels (two
    /// panels are connected when the gap between them is under the blend
    /// distance of their progress, the distance at which the blob starts to
    /// bend one toward the other), with the largest progress of their pairs.
    /// A panel with no neighbor is a cluster of one with progress 0.
    public struct Cluster: Hashable, Sendable {
        /// Indices into the outline list, ascending.
        public var members: [Int]
        /// 0...1: the blend of the group's blob is ``GlassProximityMerge/blend`` x this.
        public var progress: Double
    }

    /// Follows a list of panels from one update to the next and remembers
    /// which pairs have merged (the hysteresis state). A value; the app keeps
    /// one. Call ``reset()`` or pass the same number of outlines each time: a
    /// different count starts over.
    public struct Tracker: Sendable {
        public let merge: GlassProximityMerge
        /// The pairs of the last update.
        public private(set) var pairs: [PairState] = []
        private var latched: Set<[Int]> = []
        private var count = 0

        public init(merge: GlassProximityMerge = .standard) {
            self.merge = merge
        }

        /// Forgets every merged pair.
        public mutating func reset() {
            latched = []
            pairs = []
            count = 0
        }

        /// Measures every pair of `outlines`, updates the merged state with
        /// hysteresis and returns the clusters in order of their first
        /// member. A NaN or infinite value throws and leaves the state as it
        /// was.
        @discardableResult
        public mutating func update(_ outlines: [Outline]) throws(GlassProximityMergeError) -> [Cluster] {
            var state = outlines.count == count ? latched : []
            var measured: [PairState] = []
            for i in outlines.indices {
                for j in outlines.indices where j > i {
                    let gap = try outlines[i].gap(to: outlines[j])
                    let was = state.contains([i, j])
                    let progress = try merge.progress(gap: gap, isMerged: was)
                    let now = try merge.isMerged(afterGap: gap, wasMerged: was)
                    if now { state.insert([i, j]) } else { state.remove([i, j]) }
                    measured.append(PairState(first: i, second: j, gap: gap, progress: progress, isMerged: now))
                }
            }
            var parent = Array(0..<outlines.count)
            func root(_ i: Int) -> Int {
                var i = i
                while parent[i] != i { i = parent[i] }
                return i
            }
            // A blob's blend distance k bends an outline only toward a shape
            // closer than k, and the bend starts from nothing there. So a pair
            // is an edge once its gap is under its own k (blend x progress): up
            // to then it changes nothing. A panel that is not joined to the
            // group but is closer than the group's k joins it, which also
            // starts from nothing: the group's one blend distance never makes
            // a third panel pop.
            var strongest = [Double](repeating: 0, count: outlines.count)
            for pair in measured where pair.progress > 0 && pair.gap < merge.blend * pair.progress {
                let a = root(pair.first), b = root(pair.second)
                if a != b { parent[b] = a }
            }
            for pair in measured where pair.progress > 0 && pair.gap < merge.blend * pair.progress {
                strongest[root(pair.first)] = max(strongest[root(pair.first)], pair.progress)
            }
            var changed = true
            while changed {
                changed = false
                for pair in measured {
                    let a = root(pair.first), b = root(pair.second)
                    guard a != b, pair.gap < merge.blend * max(strongest[a], strongest[b]) else { continue }
                    parent[b] = a
                    strongest[a] = max(strongest[a], strongest[b])
                    changed = true
                }
            }
            var clusters: [Int: Cluster] = [:]
            for i in outlines.indices {
                let r = root(i)
                clusters[r, default: Cluster(members: [], progress: strongest[r])].members.append(i)
            }
            latched = state
            count = outlines.count
            pairs = measured
            return clusters.values.sorted { $0.members[0] < $1.members[0] }
        }
    }

    // MARK: The blob

    /// The cluster as one blob in `frame`'s frame units (the origin is the
    /// center of the frame, 1 is half its shorter side), ready for
    /// ``GlassParameters/shape`` of a panel whose frame is `frame`. A cluster
    /// of one is the exact single outline. Only the first
    /// ``GlassShape/maximumPrimitives`` members are used.
    public func blob(for cluster: Cluster, of outlines: [Outline], in frame: CGRect) throws(GlassProximityMergeError) -> GlassBlob {
        let unit = Double(min(frame.width, frame.height)) / 2
        guard unit.isFinite, unit > 0 else { throw .emptyFrame }
        let origin = CGPoint(x: frame.midX, y: frame.midY)
        let parts = cluster.members.filter { outlines.indices.contains($0) }.prefix(GlassShape.maximumPrimitives)
        let progress = min(max(cluster.progress, 0), 1)
        return GlassBlob(
            primitives: parts.map { outlines[$0].primitive(origin: origin, unit: unit) },
            smoothness: blend * progress / unit,
            interiorSmoothness: interiorBlend * progress / unit
        )
    }
}
