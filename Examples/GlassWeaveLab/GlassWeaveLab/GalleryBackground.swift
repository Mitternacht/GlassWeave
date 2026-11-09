import CoreGraphics
import GlassWeave
import Metal

/// What the glow gallery's background shows: everything its shader reads,
/// in points, so the gallery can tell when a new frame is needed.
///
/// The background is a pure function of these values. The gallery compares
/// the values of the next draw with those of the frame on screen and produces
/// a new frame only when they differ (a layout or scroll change, a theme step,
/// a selection step), so an animated glass interior, which the surface's own
/// effect clock redraws, never re-renders the background.
struct GalleryBackdrop: Equatable {
    struct Capsule: Equatable {
        var rect: CGRect
        /// The edge color, sRGB-encoded.
        var red: Double
        var green: Double
        var blue: Double
        /// How strongly the floor reflects it, 0...1.
        var reflection: Double
    }

    var pixelWidth = 0
    var pixelHeight = 0
    var displayScale = 1.0
    /// 0 for the light theme, 1 for the dark one; in between while the theme
    /// changes.
    var theme = 0.0
    var size = CGSize.zero
    var track = CGRect.zero
    var stage = CGRect.zero
    var bar = CGRect.zero
    var capsules: [Capsule] = []
    var showsReflections = true

    /// The shader's parameter block (`GalleryBackground.metal`).
    var shaderParameters: [SIMD4<Float>] {
        func rect(_ r: CGRect) -> SIMD4<Float> {
            SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height))
        }
        var block: [SIMD4<Float>] = [
            SIMD4(Float(displayScale), Float(theme), Float(size.width), Float(size.height)),
            rect(track), rect(stage), rect(bar),
            SIMD4(Float(min(capsules.count, 3)), showsReflections ? 1 : 0, 0, 0),
        ]
        for index in 0..<3 {
            block.append(index < capsules.count ? rect(capsules[index].rect) : .zero)
        }
        for index in 0..<3 {
            guard index < capsules.count else { block.append(.zero); continue }
            let capsule = capsules[index]
            block.append(SIMD4(Float(capsule.red), Float(capsule.green), Float(capsule.blue), Float(capsule.reflection)))
        }
        return block
    }
}

/// Renders the gallery's background into pooled textures, on demand.
///
/// Each frame is rendered in the command buffer GlassWeave then samples it
/// in (`GlassSurfaceView.setFrameProducer`), so the background and every
/// panel's refraction come from the same frame. At most ``textureLimit``
/// textures exist; when none is free the producer skips (the surface draws
/// the current frame). The shader writes `bgra8Unorm` and GlassWeave samples
/// a `bgra8Unorm_srgb` view, as in ``ProceduralBackground``.
final class GalleryBackground {
    enum Failure: Error, CustomStringConvertible {
        case shaderUnavailable(String)

        var description: String {
            switch self {
            case let .shaderUnavailable(reason): "The gallery background shader is unavailable: \(reason)."
            }
        }
    }

    /// The presented frame plus the surface's two frames in flight.
    static let textureLimit = 3

    private let pipeline: any MTLRenderPipelineState
    private let pool: FrameTexturePool
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private var nextFrameID: UInt64 = 1

    /// Frames produced so far.
    private(set) var producedCount = 0

    init(device: any MTLDevice) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw Failure.shaderUnavailable("no default library in the app bundle")
        }
        guard let vertex = library.makeFunction(name: "gallery_background_vertex"),
              let fragment = library.makeFunction(name: "gallery_background_fragment")
        else {
            throw Failure.shaderUnavailable("missing gallery_background functions")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "GlassWeaveLab gallery background"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw Failure.shaderUnavailable(String(describing: error))
        }
        pool = FrameTexturePool(
            device: device,
            descriptor: FrameTexturePool.Descriptor(
                pixelFormat: .bgra8Unorm,
                usage: [.renderTarget, .shaderRead, .pixelFormatView],
                sampledPixelFormat: BackgroundColorConvention.sRGBOpaque.requiredPixelFormat
            ),
            capacity: Self.textureLimit
        )
        start = clock.now
    }

    /// Encodes the background for `backdrop` into `commandBuffer` and returns
    /// its lease, or `nil` when no texture is free (nothing is encoded then).
    func encodeFrame(into commandBuffer: any MTLCommandBuffer, backdrop: GalleryBackdrop) -> BackgroundFrameLease? {
        guard let pooled = pool.checkout(width: backdrop.pixelWidth, height: backdrop.pixelHeight) else {
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
        let frameID = nextFrameID
        nextFrameID += 1
        var parameters = backdrop.shaderParameters
        encoder.label = "GlassWeaveLab gallery background \(frameID)"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&parameters, length: parameters.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        producedCount += 1
        let frame = BackgroundFrame(
            texture: pooled.texture,
            frameID: frameID,
            timestamp: clock.now - start,
            colorConvention: .sRGBOpaque,
            readiness: .encoded(in: commandBuffer)
        )
        return pool.lease(frame, using: pooled) { _ in }
    }

    /// Gives free textures back to Metal while the gallery is not visible.
    func trim() {
        pool.trim()
    }
}
