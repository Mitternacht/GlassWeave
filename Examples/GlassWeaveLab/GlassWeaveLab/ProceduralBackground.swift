import GlassWeave
import Metal

/// The laboratory's single animation clock.
///
/// Time advances by exactly one 1/60 s step per tick, not by wall time, so
/// tick *n* always shows content time *n* / 60 s. A late or dropped display
/// update slows the animation instead of skipping content, which keeps every
/// produced frame reproducible. Reset returns to tick 0.
struct DeterministicClock {
    static let ticksPerSecond = 60

    private(set) var ticks: UInt64 = 0

    /// Content time in seconds.
    var seconds: Double {
        Double(ticks) / Double(Self.ticksPerSecond)
    }

    mutating func advance() {
        ticks += 1
    }

    mutating func reset() {
        ticks = 0
    }
}

/// The app-owned procedural background: a GPU-rendered moving pattern that is
/// a pure function of the clock's content time.
///
/// Each frame is rendered into a texture from a GlassWeave
/// `FrameTexturePool`, in the command buffer that GlassWeave then uses to
/// sample it (`GlassRenderer.drawProducing`), so the visible background and
/// the panel's refraction come from that one frame. The pool takes a texture
/// back only after GlassWeave releases its frame, which happens after the
/// last GPU use completes. At most ``textureLimit`` textures exist; when none
/// is free the producer skips the frame (the surface redraws the current
/// one) instead of allocating more.
///
/// Rendering writes a `bgra8Unorm` texture, because the iOS Simulator cannot
/// write sRGB textures, and hands GlassWeave a `bgra8Unorm_srgb` view of it,
/// the one source format GlassWeave accepts.
final class ProceduralBackground {
    enum Failure: Error, CustomStringConvertible {
        case shaderUnavailable(String)

        var description: String {
            switch self {
            case let .shaderUnavailable(reason): "The laboratory background shader is unavailable: \(reason)."
            }
        }
    }

    /// Textures that may exist at once: the presented frame plus the
    /// surface's in-flight bound (two), so a free texture exists whenever the
    /// surface may draw.
    static let textureLimit = 3

    let device: any MTLDevice
    private let pipeline: any MTLRenderPipelineState
    private let pool: FrameTexturePool
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant

    /// Frames produced so far.
    private(set) var producedCount = 0
    /// The most recently produced frame and its content time.
    private(set) var lastProduced: (frameID: UInt64, contentSeconds: Double)?

    init(device: any MTLDevice) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw Failure.shaderUnavailable("no default library in the app bundle")
        }
        guard let vertex = library.makeFunction(name: "lab_background_vertex"),
              let fragment = library.makeFunction(name: "lab_background_fragment")
        else {
            throw Failure.shaderUnavailable("missing lab_background functions")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "GlassWeaveLab procedural background"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw Failure.shaderUnavailable(String(describing: error))
        }
        self.device = device
        self.pool = FrameTexturePool(
            device: device,
            descriptor: FrameTexturePool.Descriptor(
                pixelFormat: .bgra8Unorm,
                usage: [.renderTarget, .shaderRead, .pixelFormatView],
                sampledPixelFormat: BackgroundColorConvention.sRGBOpaque.requiredPixelFormat
            ),
            capacity: Self.textureLimit
        )
        self.start = clock.now
    }

    /// Encodes frame `frameID` into `commandBuffer` and returns its lease,
    /// or `nil` when no texture is free (nothing is encoded then).
    ///
    /// - Parameters:
    ///   - contentSeconds: The deterministic clock's time.
    ///   - displayScale: Pixels per point, so the pattern is laid out in points.
    ///   - stripCenterY: Where the frame-ID strip runs, in pixels from the
    ///     top, or `nil` to omit it.
    ///   - onRelease: Called once GlassWeave released the frame, after the
    ///     texture is back in the pool.
    func encodeFrame(
        into commandBuffer: any MTLCommandBuffer,
        pixelSize: (width: Int, height: Int),
        frameID: UInt64,
        contentSeconds: Double,
        displayScale: Double,
        stripCenterY: Double?,
        onRelease: @escaping @Sendable (BackgroundFrameRelease) -> Void
    ) -> BackgroundFrameLease? {
        guard let pooled = pool.checkout(width: pixelSize.width, height: pixelSize.height) else {
            return nil
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = pooled.storage
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            pool.returnUnused(pooled)
            return nil
        }
        var parameters: [Float] = [
            Float(contentSeconds),
            Float(displayScale),
            Float(frameID % (1 << 24)),
            stripCenterY == nil ? 0 : 1,
            Float(stripCenterY ?? 0),
        ]
        encoder.label = "GlassWeaveLab background frame \(frameID)"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&parameters, length: parameters.count * MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        producedCount += 1
        lastProduced = (frameID, contentSeconds)
        let frame = BackgroundFrame(
            texture: pooled.texture,
            frameID: frameID,
            timestamp: clock.now - start,
            colorConvention: .sRGBOpaque,
            readiness: .encoded(in: commandBuffer)
        )
        return pool.lease(frame, using: pooled, onRelease: onRelease)
    }

    /// Gives free textures back to Metal, for example while the stage is
    /// hidden. Textures still in use go when their frames are released.
    func trim() {
        pool.trim()
    }

    /// The texture pool's counts, for diagnostics.
    var poolStatistics: FrameTexturePool.Statistics {
        pool.statistics
    }
}
