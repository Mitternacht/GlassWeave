import GlassWeave
import Metal

/// The laboratory's app-owned background producer: a deterministic
/// four-corner orientation pattern in a private sRGB texture.
///
/// Each frame is a new texture, uploaded with a blit committed to the same
/// queue the renderer submits to, so the renderer's same-queue readiness
/// contract holds. The producer never reuses a texture, so its release
/// handler only reports what happened to the frame.
struct PatternSource {
    enum Failure: Error, CustomStringConvertible {
        case resourceCreation(String)

        var description: String {
            switch self {
            case let .resourceCreation(what): "Could not create \(what)."
            }
        }
    }

    /// The pattern's pixel size: 4:3 landscape, so aspect-fill cropping is
    /// visible in both portrait and landscape hosts.
    static let width = 640
    static let height = 480

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant

    /// - Parameter queue: The queue the renderer submits to; uploads are
    ///   committed to it so same-queue readiness holds.
    init(queue: any MTLCommandQueue) {
        self.device = queue.device
        self.queue = queue
        self.start = clock.now
    }

    /// Produces frame `frameID` and wraps it in a lease. The upload is
    /// committed to ``queue`` before this returns.
    func makeFrame(
        frameID: UInt64,
        onRelease: @escaping @Sendable (BackgroundFrameRelease) -> Void
    ) throws -> BackgroundFrameLease {
        let pattern = OrientationPattern(width: Self.width, height: Self.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: BackgroundColorConvention.sRGBOpaque.requiredPixelFormat,
            width: pattern.width, height: pattern.height, mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw Failure.resourceCreation("the pattern texture")
        }
        texture.label = "GlassWeaveLab pattern frame \(frameID)"

        let bytes = pattern.bgraBytes()
        guard let staging = device.makeBuffer(bytes: bytes, length: bytes.count, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else {
            throw Failure.resourceCreation("the pattern upload")
        }
        let bytesPerRow = pattern.width * 4
        blit.copy(
            from: staging, sourceOffset: 0,
            sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytes.count,
            sourceSize: MTLSize(width: pattern.width, height: pattern.height, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.label = "GlassWeaveLab pattern upload \(frameID)"
        commandBuffer.commit()

        let frame = BackgroundFrame(
            texture: texture,
            frameID: frameID,
            timestamp: clock.now - start,
            colorConvention: .sRGBOpaque,
            readiness: .committed(on: queue)
        )
        return BackgroundFrameLease(frame: frame, onRelease: onRelease)
    }
}
