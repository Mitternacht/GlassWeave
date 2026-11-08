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
/// Each frame is rendered into its own texture, in the command buffer that
/// GlassWeave then uses to sample it (`GlassRenderer.drawProducing`), so the
/// visible background and the panel's refraction come from that one frame.
/// Textures are recycled only after their lease is released, which happens
/// after the last GPU use completes. At most ``textureLimit`` textures exist;
/// when none is free the producer skips the frame (the surface redraws the
/// current one) instead of allocating more.
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

    /// Textures that may exist at once: one presented, one in flight, one
    /// being produced.
    static let textureLimit = 3

    let device: any MTLDevice
    private let pipeline: any MTLRenderPipelineState
    private var slots: [Slot] = []
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant

    /// Frames produced so far.
    private(set) var producedCount = 0
    /// Frames skipped because every texture was still in use.
    private(set) var coalescedCount = 0
    /// The most recently produced frame and its content time.
    private(set) var lastProduced: (frameID: UInt64, contentSeconds: Double)?

    private struct Slot {
        let id: Int
        let storage: any MTLTexture
        let sampled: any MTLTexture
        var inUse: Bool
    }

    private var nextSlotID = 0

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
    ///   - onRelease: Called once GlassWeave released the frame.
    func encodeFrame(
        into commandBuffer: any MTLCommandBuffer,
        pixelSize: (width: Int, height: Int),
        frameID: UInt64,
        contentSeconds: Double,
        displayScale: Double,
        stripCenterY: Double?,
        onRelease: @escaping @Sendable (BackgroundFrameRelease) -> Void
    ) -> BackgroundFrameLease? {
        guard let slotIndex = freeSlot(width: pixelSize.width, height: pixelSize.height) else {
            coalescedCount += 1
            return nil
        }
        let slot = slots[slotIndex]
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = slot.storage
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
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

        slots[slotIndex].inUse = true
        producedCount += 1
        lastProduced = (frameID, contentSeconds)
        let slotID = slot.id
        let frame = BackgroundFrame(
            texture: slot.sampled,
            frameID: frameID,
            timestamp: clock.now - start,
            colorConvention: .sRGBOpaque,
            readiness: .encoded(in: commandBuffer)
        )
        return BackgroundFrameLease(frame: frame) { [weak self] release in
            Task { @MainActor in self?.recycle(slotID: slotID) }
            onRelease(release)
        }
    }

    /// A free texture of the requested size, creating one within the limit.
    /// Free textures of another size (from before a resize) are dropped.
    private func freeSlot(width: Int, height: Int) -> Int? {
        slots.removeAll { !$0.inUse && ($0.storage.width != width || $0.storage.height != height) }
        if let index = slots.firstIndex(where: { !$0.inUse }) {
            return index
        }
        guard slots.count < Self.textureLimit else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead, .pixelFormatView]
        guard let storage = device.makeTexture(descriptor: descriptor),
              let sampled = storage.makeTextureView(pixelFormat: BackgroundColorConvention.sRGBOpaque.requiredPixelFormat)
        else { return nil }
        storage.label = "GlassWeaveLab background \(nextSlotID)"
        slots.append(Slot(id: nextSlotID, storage: storage, sampled: sampled, inUse: false))
        nextSlotID += 1
        return slots.count - 1
    }

    /// Returns a released texture to the pool.
    private func recycle(slotID: Int) {
        if let index = slots.firstIndex(where: { $0.id == slotID }) {
            slots[index].inUse = false
        }
    }

    /// Textures currently allocated, for diagnostics.
    var textureCount: Int {
        slots.count
    }
}
