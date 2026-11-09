import Foundation

/// The shape of a panel as the optics see it: the interface later shape
/// kinds (ellipses, squircles, blobs; GW-26) plug into.
///
/// The thick-lens optics, the light model, and frost ask the shape for four
/// things at a pixel, and nothing else about it:
///
/// | Quantity | Meaning |
/// | --- | --- |
/// | ``signedDistance(at:)`` | Pixels to the outline: negative inside, zero on it, positive outside. Decides coverage and the antialiased edge. |
/// | ``outwardNormal(at:)`` | The unit direction in which ``lensDepth(at:)`` falls: perpendicular to the iso-contours of the depth, pointing out of the shape. |
/// | ``lensDepth(at:)`` | How deep the pixel is inside the shape, in pixels, 0 at and outside the outline. **C1**: its gradient is continuous everywhere inside up to the shape's medial axis, and its iso-contours keep a corner radius of at least the bevel width. A height `h = H × s(depth / bevel)` built on it therefore has no crease along corner diagonals, even when the bevel is wider than the corner radius. |
/// | ``inscribedRadius`` | The radius of the largest circle inside the shape, in pixels. A dome's bevel. |
///
/// The shader has the same interface as `GWShapeSample` and
/// `gw_shape_rounded_rect` in `Glass.metal`; both implement the rounded
/// rectangle today.
package protocol GlassShapeField {
    func signedDistance(at pixel: SIMD2<Double>) -> Double
    func outwardNormal(at pixel: SIMD2<Double>) -> SIMD2<Double>
    func lensDepth(at pixel: SIMD2<Double>) -> Double
    var inscribedRadius: Double { get }
}

/// The rounded-rectangle shape field.
///
/// The outline has `cornerRadius`; the lens depth and the normal come from
/// the rounded rectangle of `fieldRadius` (at least the bevel width, at most
/// the inscribed radius), the same field ``GlassPanelGeometry/normalRadius``
/// uses, so the normal and the height agree.
package struct RoundedRectangleField: GlassShapeField, Equatable {
    package var center: SIMD2<Double>
    package var halfSize: SIMD2<Double>
    package var cornerRadius: Double
    package var fieldRadius: Double

    package var inscribedRadius: Double {
        min(halfSize.x, halfSize.y)
    }

    package func signedDistance(at pixel: SIMD2<Double>) -> Double {
        Self.distance(pixel - center, halfSize: halfSize, radius: cornerRadius)
    }

    package func outwardNormal(at pixel: SIMD2<Double>) -> SIMD2<Double> {
        let q = pixel - center
        let d = SIMD2(abs(q.x), abs(q.y)) - (halfSize - fieldRadius)
        let sign = { (x: Double) in x > 0 ? 1.0 : (x < 0 ? -1.0 : 0.0) }
        if d.x > 0, d.y > 0 {
            let length = (d.x * d.x + d.y * d.y).squareRoot()
            return SIMD2(d.x / length * sign(q.x), d.y / length * sign(q.y))
        }
        return d.x > d.y ? SIMD2(sign(q.x), 0) : SIMD2(0, sign(q.y))
    }

    package func lensDepth(at pixel: SIMD2<Double>) -> Double {
        max(-Self.distance(pixel - center, halfSize: halfSize, radius: fieldRadius), 0)
    }

    /// Signed distance to a rounded rectangle centered at the origin.
    static func distance(_ q: SIMD2<Double>, halfSize: SIMD2<Double>, radius: Double) -> Double {
        let d = SIMD2(abs(q.x), abs(q.y)) - (halfSize - radius)
        let outside = SIMD2(max(d.x, 0), max(d.y, 0))
        return (outside.x * outside.x + outside.y * outside.y).squareRoot() + min(max(d.x, d.y), 0) - radius
    }
}
