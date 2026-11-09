import CoreGraphics
import GlassWeave
import Metal
import QuartzCore
import UIKit

/// What one half of the versus screen's backdrop shows: everything
/// `VersusBackground.metal` reads, in points. The picture is a pure function
/// of the screen position, so two targets that cover different parts of the
/// screen show the same pixels where they meet.
struct VersusBackdrop: Equatable {
    var pixelWidth = 0
    var pixelHeight = 0
    var displayScale = 1.0
    /// This target's top-left corner on the screen, in points.
    var origin = CGPoint.zero
    var screenSize = CGSize.zero
    var dark = false

    var shaderParameters: [SIMD4<Float>] {
        [
            SIMD4(Float(origin.x), Float(origin.y), Float(displayScale), dark ? 1 : 0),
            SIMD4(Float(screenSize.width), Float(screenSize.height), 0, 0),
        ]
    }
}

/// Draws the versus backdrop with one pipeline, into pooled frames for the
/// glass surface (``encodeFrame(into:backdrop:)``) or into a Metal layer's
/// drawable for the native half (``draw(_:into:)``), both from the same
/// shader.
final class VersusBackdropRenderer {
    enum Failure: Error, CustomStringConvertible {
        case shaderUnavailable(String)
        case noCommandQueue

        var description: String {
            switch self {
            case let .shaderUnavailable(reason): "The versus backdrop shader is unavailable: \(reason)."
            case .noCommandQueue: "Could not create a command queue."
            }
        }
    }

    /// The presented frame plus the surface's two frames in flight.
    static let textureLimit = 3

    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let pool: FrameTexturePool
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private var nextFrameID: UInt64 = 1

    /// Frames produced for the glass surface so far.
    private(set) var producedCount = 0

    init(device: any MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else { throw Failure.noCommandQueue }
        queue.label = "GlassWeaveLab versus backdrop"
        guard let library = device.makeDefaultLibrary() else {
            throw Failure.shaderUnavailable("no default library in the app bundle")
        }
        guard let vertex = library.makeFunction(name: "versus_background_vertex"),
              let fragment = library.makeFunction(name: "versus_background_fragment")
        else {
            throw Failure.shaderUnavailable("missing versus_background functions")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "GlassWeaveLab versus backdrop"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw Failure.shaderUnavailable(String(describing: error))
        }
        self.device = device
        self.queue = queue
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

    private func encodePass(_ pass: MTLRenderPassDescriptor, into commandBuffer: any MTLCommandBuffer, backdrop: VersusBackdrop, label: String) -> Bool {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var parameters = backdrop.shaderParameters
        encoder.label = label
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&parameters, length: parameters.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    /// Encodes the backdrop into `commandBuffer` for the glass surface and
    /// returns its lease, or `nil` when no texture is free.
    func encodeFrame(into commandBuffer: any MTLCommandBuffer, backdrop: VersusBackdrop) -> BackgroundFrameLease? {
        guard let pooled = pool.checkout(width: backdrop.pixelWidth, height: backdrop.pixelHeight) else {
            return nil
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = pooled.storage
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let frameID = nextFrameID
        guard encodePass(pass, into: commandBuffer, backdrop: backdrop, label: "GlassWeaveLab versus backdrop \(frameID)") else {
            pool.returnUnused(pooled)
            return nil
        }
        nextFrameID += 1
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

    /// Draws the backdrop into the next drawable of `layer` and presents it.
    func draw(_ backdrop: VersusBackdrop, into layer: CAMetalLayer) {
        guard backdrop.pixelWidth > 0, backdrop.pixelHeight > 0,
              let drawable = layer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer()
        else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard encodePass(pass, into: commandBuffer, backdrop: backdrop, label: "GlassWeaveLab versus backdrop (native half)") else { return }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Gives free textures back to Metal while the screen is not visible.
    func trim() {
        pool.trim()
    }
}

/// The native half's backdrop: a plain Metal layer that draws the shared
/// shader once per layout or appearance change. It is not a GlassWeave
/// surface: it has no panel, no renderer of its own and no display loop.
final class VersusBackdropView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private let renderer: VersusBackdropRenderer
    /// This view's top-left corner on the screen and the screen's size, in
    /// points; the screen sets them.
    var screenGeometry: (origin: CGPoint, size: CGSize) = (.zero, .zero) {
        didSet { setNeedsLayout() }
    }

    private var metalLayer: CAMetalLayer {
        // `layerClass` makes the backing layer a `CAMetalLayer`.
        layer as! CAMetalLayer // swiftlint:disable:this force_cast
    }

    init(renderer: VersusBackdropRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = max(traitCollection.displayScale, 1)
        metalLayer.contentsScale = scale
        let pixels = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard pixels.width > 0, pixels.height > 0, screenGeometry.size.width > 0 else { return }
        metalLayer.drawableSize = pixels
        var backdrop = VersusBackdrop()
        backdrop.pixelWidth = Int(pixels.width)
        backdrop.pixelHeight = Int(pixels.height)
        backdrop.displayScale = Double(scale)
        backdrop.origin = screenGeometry.origin
        backdrop.screenSize = screenGeometry.size
        backdrop.dark = traitCollection.userInterfaceStyle == .dark
        renderer.draw(backdrop, into: metalLayer)
    }
}
