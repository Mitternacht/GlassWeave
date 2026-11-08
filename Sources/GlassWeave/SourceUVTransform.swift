internal import GlassWeaveShaderTypes

/// An affine map between 2D coordinate spaces:
/// `mapped = xAxis * p.x + yAxis * p.y + origin`.
struct Affine2D: Equatable {
    var xAxis: SIMD2<Double>
    var yAxis: SIMD2<Double>
    var origin: SIMD2<Double>

    static let identity = Affine2D(xAxis: [1, 0], yAxis: [0, 1], origin: [0, 0])

    func apply(_ point: SIMD2<Double>) -> SIMD2<Double> {
        xAxis * point.x + yAxis * point.y + origin
    }

    /// The map that applies `self` first, then `next`.
    func followed(by next: Affine2D) -> Affine2D {
        Affine2D(
            xAxis: next.xAxis * xAxis.x + next.yAxis * xAxis.y,
            yAxis: next.xAxis * yAxis.x + next.yAxis * yAxis.y,
            origin: next.apply(origin)
        )
    }
}

/// The mapping from a destination surface to a source frame's texture.
///
/// Placement policy (v0.1): the upright valid content is scaled uniformly to
/// cover the destination and centered; whatever overflows is cropped (aspect
/// fill). Display scale does not change the mapping, only the pixel count:
/// destinations with the same aspect ratio map identically.
///
/// Spaces, in the order the map is built:
/// 1. Destination UV: origin top-left of the target, y down, [0, 1].
/// 2. Upright UV: the upright valid content, [0, 1].
/// 3. Stored UV: the valid content as stored in memory, [0, 1].
/// 4. Texture UV: the whole texture, origin top-left of texture memory.
struct SourceUVTransform: Equatable {
    /// Destination UV to texture UV.
    let map: Affine2D
    /// Texture-UV bounds half a texel inside the valid rectangle, so a
    /// linearly filtered sample never touches a texel outside it.
    let sampleClampMin: SIMD2<Double>
    let sampleClampMax: SIMD2<Double>

    init(
        destinationWidth: Int,
        destinationHeight: Int,
        textureWidth: Int,
        textureHeight: Int,
        validRect: PixelRect,
        orientation: SourceOrientation
    ) {
        precondition(destinationWidth > 0 && destinationHeight > 0, "Destination must be non-empty")
        precondition(textureWidth > 0 && textureHeight > 0, "Texture must be non-empty")
        precondition(validRect.width > 0 && validRect.height > 0, "Valid rectangle must be non-empty")

        // Upright content size in source pixels: quarter turns swap the axes.
        let swapsAxes = orientation.rotation == .clockwise90 || orientation.rotation == .clockwise270
        let uprightWidth = Double(swapsAxes ? validRect.height : validRect.width)
        let uprightHeight = Double(swapsAxes ? validRect.width : validRect.height)

        // 1 -> 2: aspect fill, centered crop.
        let destinationWidth = Double(destinationWidth)
        let destinationHeight = Double(destinationHeight)
        let scale = max(destinationWidth / uprightWidth, destinationHeight / uprightHeight)
        let visibleWidth = destinationWidth / scale / uprightWidth
        let visibleHeight = destinationHeight / scale / uprightHeight
        let toUpright = Affine2D(
            xAxis: [visibleWidth, 0],
            yAxis: [0, visibleHeight],
            origin: [(1 - visibleWidth) / 2, (1 - visibleHeight) / 2]
        )

        // 2 -> 3: undo the clockwise rotation that makes the stored image
        // upright, then undo a bottom-up row order.
        let unrotate: Affine2D = switch orientation.rotation {
        case .none: .identity
        // Stored (s, t) turns clockwise to upright (1 - t, s).
        case .clockwise90: Affine2D(xAxis: [0, -1], yAxis: [1, 0], origin: [0, 1])
        case .clockwise180: Affine2D(xAxis: [-1, 0], yAxis: [0, -1], origin: [1, 1])
        // Stored (s, t) turns counter-clockwise to upright (t, 1 - s).
        case .clockwise270: Affine2D(xAxis: [0, 1], yAxis: [-1, 0], origin: [1, 0])
        }
        let unflip: Affine2D = switch orientation.verticalOrigin {
        case .top: .identity
        case .bottom: Affine2D(xAxis: [1, 0], yAxis: [0, -1], origin: [0, 1])
        }

        // 3 -> 4: place the valid rectangle inside the texture.
        let textureWidth = Double(textureWidth)
        let textureHeight = Double(textureHeight)
        let toTexture = Affine2D(
            xAxis: [Double(validRect.width) / textureWidth, 0],
            yAxis: [0, Double(validRect.height) / textureHeight],
            origin: [Double(validRect.x) / textureWidth, Double(validRect.y) / textureHeight]
        )

        self.map = toUpright.followed(by: unrotate).followed(by: unflip).followed(by: toTexture)
        self.sampleClampMin = [
            (Double(validRect.x) + 0.5) / textureWidth,
            (Double(validRect.y) + 0.5) / textureHeight,
        ]
        self.sampleClampMax = [
            (Double(validRect.x + validRect.width) - 0.5) / textureWidth,
            (Double(validRect.y + validRect.height) - 0.5) / textureHeight,
        ]
    }

    init(destinationWidth: Int, destinationHeight: Int, frame: BackgroundFrame) {
        self.init(
            destinationWidth: destinationWidth,
            destinationHeight: destinationHeight,
            textureWidth: frame.texture.width,
            textureHeight: frame.texture.height,
            validRect: frame.validRect,
            orientation: frame.orientation
        )
    }

    /// The texture UV sampled for a destination UV, before clamping.
    func textureUV(atDestinationUV destination: SIMD2<Double>) -> SIMD2<Double> {
        map.apply(destination)
    }

    /// The record uploaded to the background fragment shader.
    var uniforms: GWBackgroundUniforms {
        GWBackgroundUniforms(
            uvFromDestinationX: SIMD2<Float>(map.xAxis),
            uvFromDestinationY: SIMD2<Float>(map.yAxis),
            uvOrigin: SIMD2<Float>(map.origin),
            sampleClampMin: SIMD2<Float>(sampleClampMin),
            sampleClampMax: SIMD2<Float>(sampleClampMax)
        )
    }
}
