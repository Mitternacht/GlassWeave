import Metal
import Synchronization
import Testing
@testable import GlassWeave

/// A device and queue for one test. Each test makes its own so tests can run
/// in parallel without sharing GPU state.
struct GPUContext {
    let device: any MTLDevice
    let queue: any MTLCommandQueue

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        queue = try #require(device.makeCommandQueue())
    }

    /// A private 2D texture. Private storage works on macOS, devices, and the
    /// Simulator alike; content arrives by blit, not CPU mapping.
    func makeTexture(
        width: Int, height: Int,
        pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb,
        usage: MTLTextureUsage = [.shaderRead]
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = usage
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    /// Copies tightly packed 4-byte pixels into `texture` with a blit
    /// committed to `queue`. Later work on the same queue sees the bytes.
    func upload(_ bytes: [UInt8], to texture: any MTLTexture) throws {
        let bytesPerRow = texture.width * 4
        let staging = try #require(device.makeBuffer(bytes: bytes, length: bytes.count, options: .storageModeShared))
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: staging, sourceOffset: 0,
            sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerRow * texture.height,
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.label = "Test upload"
        commandBuffer.commit()
    }

    /// An uploaded orientation pattern wrapped in a lease.
    func makePatternLease(
        width: Int, height: Int,
        frameID: UInt64 = 1,
        timestamp: Duration = .zero,
        validRect: PixelRect? = nil,
        orientation: SourceOrientation = .up,
        onRelease: @escaping @Sendable (BackgroundFrameRelease) -> Void = { _ in }
    ) throws -> BackgroundFrameLease {
        let texture = try makeTexture(width: width, height: height)
        try upload(OrientationPattern(width: width, height: height).bgraBytes(), to: texture)
        let frame = BackgroundFrame(
            texture: texture, frameID: frameID, timestamp: timestamp,
            validRect: validRect, orientation: orientation,
            colorConvention: .sRGBOpaque, readiness: .committed(on: queue)
        )
        return BackgroundFrameLease(frame: frame, onRelease: onRelease)
    }

    /// Uploaded BGRA bytes wrapped in a lease.
    func makeLease(
        bgra: [UInt8], width: Int, height: Int,
        frameID: UInt64 = 1,
        timestamp: Duration = .zero,
        validRect: PixelRect? = nil,
        onRelease: @escaping @Sendable (BackgroundFrameRelease) -> Void = { _ in }
    ) throws -> BackgroundFrameLease {
        precondition(bgra.count == width * height * 4)
        let texture = try makeTexture(width: width, height: height)
        try upload(bgra, to: texture)
        let frame = BackgroundFrame(
            texture: texture, frameID: frameID, timestamp: timestamp,
            validRect: validRect, colorConvention: .sRGBOpaque, readiness: .committed(on: queue)
        )
        return BackgroundFrameLease(frame: frame, onRelease: onRelease)
    }

    /// An offscreen target in the renderer's output format, cleared to
    /// `clear`. The default is transparent black: every pixel a renderer
    /// writes is opaque, so a pixel left with alpha 0 was never written.
    func makeTarget(
        width: Int, height: Int,
        clear: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    ) throws -> BackgroundDrawTarget {
        let texture = try makeTexture(
            width: width, height: height,
            pixelFormat: BackgroundRenderer.outputPixelFormat,
            usage: [.renderTarget]
        )
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clear
        pass.colorAttachments[0].storeAction = .store
        return BackgroundDrawTarget(renderPassDescriptor: pass)
    }

    /// Reads back a 4-byte-per-pixel texture after all earlier work on the
    /// queue. Suspends until the GPU finishes; never blocks a thread.
    func readBack(_ texture: any MTLTexture) async throws -> RenderedImage {
        let bytesPerRow = texture.width * 4
        let length = bytesPerRow * texture.height
        let buffer = try #require(device.makeBuffer(length: length, options: .storageModeShared))
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: length
        )
        blit.endEncoding()
        commandBuffer.label = "Test readback"
        let status = await commandBuffer.commitAndWait()
        #expect(status == .completed)
        let bytes = Array(UnsafeRawBufferPointer(start: buffer.contents(), count: length))
        return RenderedImage(width: texture.width, height: texture.height, bgra: bytes)
    }
}

extension MTLCommandBuffer {
    /// Commits and suspends until completion without blocking a thread.
    func commitAndWait() async -> MTLCommandBufferStatus {
        await withCheckedContinuation { continuation in
            addCompletedHandler { commandBuffer in
                continuation.resume(returning: commandBuffer.status)
            }
            commit()
        }
    }
}

/// Read-back BGRA bytes with pixel access.
struct RenderedImage {
    let width: Int
    let height: Int
    let bgra: [UInt8]

    func color(x: Int, y: Int) -> OrientationPattern.Color {
        let index = (y * width + x) * 4
        return OrientationPattern.Color(red: bgra[index + 2], green: bgra[index + 1], blue: bgra[index], alpha: bgra[index + 3])
    }

    /// Whether every pixel has alpha 255, so none was left unwritten.
    var isFullyOpaque: Bool {
        stride(from: 3, to: bgra.count, by: 4).allSatisfy { bgra[$0] == 255 }
    }

    /// The pixel at a destination UV (pixel centers at (i + 0.5) / width).
    func color(u: Double, v: Double) -> OrientationPattern.Color {
        color(x: min(width - 1, Int(u * Double(width))), y: min(height - 1, Int(v * Double(height))))
    }
}

extension OrientationPattern.Color {
    /// Channel-wise equality within `tolerance` (8-bit steps).
    func isClose(to other: OrientationPattern.Color, tolerance: Int = 1) -> Bool {
        abs(Int(red) - Int(other.red)) <= tolerance
            && abs(Int(green) - Int(other.green)) <= tolerance
            && abs(Int(blue) - Int(other.blue)) <= tolerance
            && abs(Int(alpha) - Int(other.alpha)) <= tolerance
    }
}

/// Records lease releases from any thread and lets a test await them.
final class ReleaseRecorder: Sendable {
    private struct State {
        var releases: [BackgroundFrameRelease] = []
        var waiters: [CheckedContinuation<BackgroundFrameRelease, Never>] = []
    }

    private let state = Mutex(State())

    var handler: @Sendable (BackgroundFrameRelease) -> Void {
        { [self] release in record(release) }
    }

    var releases: [BackgroundFrameRelease] {
        state.withLock { $0.releases }
    }

    func record(_ release: BackgroundFrameRelease) {
        let waiters = state.withLock { state in
            state.releases.append(release)
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: release) }
    }

    /// The first release, awaiting it if it has not happened yet.
    func firstRelease() async -> BackgroundFrameRelease {
        await withCheckedContinuation { continuation in
            let existing: BackgroundFrameRelease? = state.withLock { state in
                if let first = state.releases.first { return first }
                state.waiters.append(continuation)
                return nil
            }
            if let existing { continuation.resume(returning: existing) }
        }
    }
}
