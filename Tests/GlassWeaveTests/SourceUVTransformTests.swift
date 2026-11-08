import Testing
@testable import GlassWeave
import GlassWeaveShaderTypes

/// Destination-to-source UV mapping: scale, aspect crop, valid-rectangle
/// crop, rotation, vertical origin, and display-scale independence.
struct SourceUVTransformTests {
    private func transform(
        destination: (Int, Int),
        texture: (Int, Int),
        valid: PixelRect? = nil,
        orientation: SourceOrientation = .up
    ) -> SourceUVTransform {
        SourceUVTransform(
            destinationWidth: destination.0, destinationHeight: destination.1,
            textureWidth: texture.0, textureHeight: texture.1,
            validRect: valid ?? PixelRect(x: 0, y: 0, width: texture.0, height: texture.1),
            orientation: orientation
        )
    }

    private func isNear(_ a: SIMD2<Double>, _ b: SIMD2<Double>, tolerance: Double = 1e-12) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    @Test func `Same aspect maps destination corners to texture corners`() {
        let t = transform(destination: (200, 100), texture: (400, 200))
        #expect(isNear(t.textureUV(atDestinationUV: [0, 0]), [0, 0]))
        #expect(isNear(t.textureUV(atDestinationUV: [1, 0]), [1, 0]))
        #expect(isNear(t.textureUV(atDestinationUV: [0, 1]), [0, 1]))
        #expect(isNear(t.textureUV(atDestinationUV: [1, 1]), [1, 1]))
        #expect(isNear(t.textureUV(atDestinationUV: [0.25, 0.75]), [0.25, 0.75]))
    }

    @Test func `Wider destination crops the top and bottom equally`() {
        let t = transform(destination: (200, 100), texture: (100, 100))
        #expect(isNear(t.textureUV(atDestinationUV: [0, 0]), [0, 0.25]))
        #expect(isNear(t.textureUV(atDestinationUV: [1, 1]), [1, 0.75]))
        #expect(isNear(t.textureUV(atDestinationUV: [0.5, 0.5]), [0.5, 0.5]))
    }

    @Test func `Taller destination crops the left and right equally`() {
        let t = transform(destination: (100, 400), texture: (100, 100))
        #expect(isNear(t.textureUV(atDestinationUV: [0, 0]), [0.375, 0]))
        #expect(isNear(t.textureUV(atDestinationUV: [1, 1]), [0.625, 1]))
    }

    @Test func `Valid rectangle limits sampling to the content`() {
        // A 200 x 100 texture whose content is the centered 100 x 100 square.
        let t = transform(destination: (100, 100), texture: (200, 100), valid: PixelRect(x: 50, y: 0, width: 100, height: 100))
        #expect(isNear(t.textureUV(atDestinationUV: [0, 0]), [0.25, 0]))
        #expect(isNear(t.textureUV(atDestinationUV: [1, 1]), [0.75, 1]))
    }

    @Test func `Valid rectangle and aspect crop combine`() {
        // Content is the left 100 x 50 of a 200 x 100 texture; a square
        // destination keeps the middle half of the content's width.
        let t = transform(destination: (60, 60), texture: (200, 100), valid: PixelRect(x: 0, y: 0, width: 100, height: 50))
        #expect(isNear(t.textureUV(atDestinationUV: [0, 0]), [0.125, 0]))
        #expect(isNear(t.textureUV(atDestinationUV: [1, 1]), [0.375, 0.5]))
    }

    /// Where the destination's top-left and top-right corners sample, for a
    /// square source stored with each rotation.
    static let rotationCorners: [(SourceOrientation.Rotation, SIMD2<Double>, SIMD2<Double>)] = [
        (.none, [0, 0], [1, 0]),
        // Turning the stored image clockwise brings its bottom-left corner to
        // the upright top-left, and its top-left to the upright top-right.
        (.clockwise90, [0, 1], [0, 0]),
        (.clockwise180, [1, 1], [0, 1]),
        (.clockwise270, [1, 0], [1, 1]),
    ]

    @Test(arguments: rotationCorners)
    func `Rotation picks the stored corner that appears at each destination corner`(
        rotation: SourceOrientation.Rotation, topLeft: SIMD2<Double>, topRight: SIMD2<Double>
    ) {
        let t = transform(destination: (100, 100), texture: (100, 100), orientation: SourceOrientation(rotation: rotation))
        #expect(isNear(t.textureUV(atDestinationUV: [0, 0]), topLeft))
        #expect(isNear(t.textureUV(atDestinationUV: [1, 0]), topRight))
        #expect(isNear(t.textureUV(atDestinationUV: [0.5, 0.5]), [0.5, 0.5]))
    }

    @Test func `Bottom vertical origin reads rows from the end of memory`() {
        let t = transform(destination: (100, 100), texture: (100, 100), orientation: SourceOrientation(verticalOrigin: .bottom))
        #expect(isNear(t.textureUV(atDestinationUV: [0, 0]), [0, 1]))
        #expect(isNear(t.textureUV(atDestinationUV: [0, 1]), [0, 0]))
        #expect(isNear(t.textureUV(atDestinationUV: [1, 0]), [1, 1]))
    }

    @Test func `Vertical origin flips before rotation`() {
        // Bottom-up rows, then a clockwise quarter turn: the destination's
        // top-left samples stored row 0 (the image bottom), column 0.
        let t = transform(
            destination: (100, 100), texture: (100, 100),
            orientation: SourceOrientation(rotation: .clockwise90, verticalOrigin: .bottom)
        )
        #expect(isNear(t.textureUV(atDestinationUV: [0, 0]), [0, 0]))
        #expect(isNear(t.textureUV(atDestinationUV: [1, 0]), [0, 1]))
    }

    @Test func `Quarter turn swaps the aspect used for the crop`() {
        // Stored landscape 200 x 100; upright it is portrait 100 x 200.
        let rotated = SourceOrientation(rotation: .clockwise90)
        let portrait = transform(destination: (100, 200), texture: (200, 100), orientation: rotated)
        #expect(isNear(portrait.textureUV(atDestinationUV: [0, 0]), [0, 1]))
        #expect(isNear(portrait.textureUV(atDestinationUV: [1, 1]), [1, 0]))

        // A square destination keeps the middle half of the upright height,
        // which is the middle half of the stored width.
        let square = transform(destination: (100, 100), texture: (200, 100), orientation: rotated)
        #expect(isNear(square.textureUV(atDestinationUV: [0, 0]), [0.25, 1]))
        #expect(isNear(square.textureUV(atDestinationUV: [1, 1]), [0.75, 0]))
    }

    @Test(arguments: [1, 2, 3])
    func `Display scale changes pixel count but not the mapping`(scale: Int) {
        let reference = transform(destination: (393, 852), texture: (640, 480))
        let scaled = transform(destination: (393 * scale, 852 * scale), texture: (640, 480))
        #expect(isNear(scaled.map.xAxis, reference.map.xAxis))
        #expect(isNear(scaled.map.yAxis, reference.map.yAxis))
        #expect(isNear(scaled.map.origin, reference.map.origin))
    }

    @Test func `Rotating the host keeps the content upright and centered`() {
        let portrait = transform(destination: (1206, 2622), texture: (640, 480))
        let landscape = transform(destination: (2622, 1206), texture: (640, 480))
        for t in [portrait, landscape] {
            // Each destination corner stays in the matching source quadrant.
            let topLeft = t.textureUV(atDestinationUV: [0, 0])
            let bottomRight = t.textureUV(atDestinationUV: [1, 1])
            #expect(topLeft.x < 0.5 && topLeft.y < 0.5)
            #expect(bottomRight.x > 0.5 && bottomRight.y > 0.5)
            #expect(isNear(t.textureUV(atDestinationUV: [0.5, 0.5]), [0.5, 0.5]))
        }
        // A 4:3 source in a portrait host shows its full height and crops
        // its width; in a landscape host it shows its full width and crops
        // its height.
        let portraitTopLeft = portrait.textureUV(atDestinationUV: [0, 0])
        #expect(abs(portraitTopLeft.y) < 1e-12 && portraitTopLeft.x > 0.3)
        let landscapeTopLeft = landscape.textureUV(atDestinationUV: [0, 0])
        #expect(abs(landscapeTopLeft.x) < 1e-12 && landscapeTopLeft.y > 0.15)
    }

    @Test func `Sample clamp stays half a texel inside the valid rectangle`() {
        let t = transform(destination: (10, 10), texture: (200, 100), valid: PixelRect(x: 50, y: 10, width: 100, height: 80))
        #expect(isNear(t.sampleClampMin, [50.5 / 200, 10.5 / 100]))
        #expect(isNear(t.sampleClampMax, [149.5 / 200, 89.5 / 100]))
    }

    @Test func `Uniform record carries the transform in single precision`() {
        let t = transform(destination: (300, 100), texture: (128, 64), valid: PixelRect(x: 8, y: 4, width: 96, height: 48), orientation: SourceOrientation(rotation: .clockwise180))
        let u = t.uniforms
        #expect(u.uvFromDestinationX == SIMD2<Float>(t.map.xAxis))
        #expect(u.uvFromDestinationY == SIMD2<Float>(t.map.yAxis))
        #expect(u.uvOrigin == SIMD2<Float>(t.map.origin))
        #expect(u.sampleClampMin == SIMD2<Float>(t.sampleClampMin))
        #expect(u.sampleClampMax == SIMD2<Float>(t.sampleClampMax))
    }

    @Test func `Composition applies the first map first`() {
        let scale = Affine2D(xAxis: [2, 0], yAxis: [0, 3], origin: [0, 0])
        let shift = Affine2D(xAxis: [1, 0], yAxis: [0, 1], origin: [5, 7])
        #expect(scale.followed(by: shift).apply([1, 1]) == [7, 10])
        #expect(shift.followed(by: scale).apply([1, 1]) == [12, 24])
    }
}
