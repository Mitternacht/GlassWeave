import Metal
import Synchronization

/// A fixed number of reusable source textures for a frame producer.
///
/// A texture goes back to the pool only when GlassWeave releases the frame
/// that uses it, which happens after the last GPU submission sampling it
/// has completed (see ``BackgroundFrameLease``). So a producer can never
/// write into a texture the GPU may still read.
///
/// The pool never holds more than ``capacity`` textures, counting the ones
/// in use. When all of them are in use, ``checkout(width:height:)`` returns
/// `nil` and the producer skips that frame: under overload, obsolete frames
/// are dropped instead of queued, and nothing waits.
///
/// - **Resize.** Checking out a new size discards free textures of other
///   sizes at once. Textures of another size that are still in use are
///   discarded when their frame is released, not reused.
/// - **Trim.** ``trim()`` discards every free texture (for example, while the
///   host is hidden) and marks those in use for discarding on release.
/// - **Teardown.** The pool may be deallocated while frames are in flight.
///   Each in-flight texture stays alive through the frame and the command
///   buffers that use it until they complete; returning it then is harmless.
///
/// Use a pool from one isolation domain at a time, like the renderer.
/// Returns arrive from Metal completion threads; they touch only the pool's
/// locked ledger, never a texture.
public final class FrameTexturePool {
    /// How the pool creates each texture.
    public struct Descriptor: Sendable {
        /// The storage format the producer writes.
        public var pixelFormat: MTLPixelFormat
        public var usage: MTLTextureUsage
        public var storageMode: MTLStorageMode
        /// A different format for the view handed to consumers, or `nil` to
        /// hand over the storage texture itself. For example, a producer that
        /// renders `bgra8Unorm` (the iOS Simulator cannot render to sRGB
        /// targets) hands GlassWeave a `bgra8Unorm_srgb` view; the storage
        /// then needs `.pixelFormatView` usage.
        public var sampledPixelFormat: MTLPixelFormat?

        public init(
            pixelFormat: MTLPixelFormat,
            usage: MTLTextureUsage,
            storageMode: MTLStorageMode = .private,
            sampledPixelFormat: MTLPixelFormat? = nil
        ) {
            self.pixelFormat = pixelFormat
            self.usage = usage
            self.storageMode = storageMode
            self.sampledPixelFormat = sampledPixelFormat
        }
    }

    /// What the pool has done, for diagnostics and lifecycle tests.
    public struct Statistics: Hashable, Sendable {
        public var capacity: Int
        /// Textures created since the pool was made.
        public var allocations: Int
        /// Successful checkouts, new or reused.
        public var checkouts: Int
        /// Checkouts refused because ``capacity`` textures were in use.
        public var exhaustedCheckouts: Int
        /// Textures discarded after a size change or a trim.
        public var discarded: Int
        /// Textures the pool holds now, in use or free.
        public var liveTextures: Int
        /// Textures whose frame has not been released yet.
        public var texturesInUse: Int
        /// The GPU memory of the live textures, from `MTLResource.allocatedSize`.
        public var liveBytes: Int
    }

    public let device: any MTLDevice
    public let descriptor: Descriptor
    /// The most textures the pool ever holds, in use or free.
    public let capacity: Int

    private let ledger: PoolLedgerBox
    private var textures: [Int: PooledTexture] = [:]

    /// - Parameters:
    ///   - device: The device the textures are created on: the renderer's.
    ///   - descriptor: How each texture is created.
    ///   - capacity: The most textures the pool holds, in use or free. At
    ///     least one.
    public init(device: any MTLDevice, descriptor: Descriptor, capacity: Int) {
        precondition(capacity > 0, "A texture pool needs a capacity of at least one")
        self.device = device
        self.descriptor = descriptor
        self.capacity = capacity
        self.ledger = PoolLedgerBox(capacity: capacity)
    }

    /// A texture of the given pixel size that no frame uses, or `nil` when
    /// ``capacity`` textures are in use (or Metal could not allocate one).
    ///
    /// The texture's content is undefined; encode writes that cover it.
    /// Hand it to a frame with ``lease(_:using:onRelease:)``, or give it back
    /// unused with ``returnUnused(_:)``.
    public func checkout(width: Int, height: Int) -> PooledTexture? {
        precondition(width > 0 && height > 0, "A pooled texture needs a positive size")
        let decision = ledger.state.withLock { $0.checkout(width: width, height: height) }
        reconcile()
        switch decision {
        case .exhausted:
            return nil
        case let .reuse(id):
            return textures[id]
        case let .allocate(id):
            guard let texture = makeTexture(id: id, width: width, height: height) else {
                ledger.state.withLock { $0.allocationFailed(id: id) }
                return nil
            }
            textures[id] = texture
            return texture
        }
    }

    /// Wraps `frame`, whose texture must be `texture`'s ``PooledTexture/texture``,
    /// in a lease that returns `texture` to this pool when GlassWeave releases
    /// the frame, before calling `onRelease`.
    public func lease(
        _ frame: BackgroundFrame,
        using texture: PooledTexture,
        onRelease: @escaping @Sendable (BackgroundFrameRelease) -> Void
    ) -> BackgroundFrameLease {
        precondition(frame.texture === texture.texture, "The frame must use the pooled texture's sampled texture")
        let ledger = ledger
        let id = texture.id
        return BackgroundFrameLease(frame: frame) { release in
            ledger.state.withLock { $0.didReturn(id: id) }
            onRelease(release)
        }
    }

    /// Gives back a checked-out texture that no frame uses, for example
    /// when encoding failed. Its content must not be in use by the GPU.
    public func returnUnused(_ texture: PooledTexture) {
        ledger.state.withLock { $0.didReturn(id: texture.id) }
        reconcile()
    }

    /// Discards every free texture now and every texture in use when its
    /// frame is released. Later checkouts allocate again.
    public func trim() {
        ledger.state.withLock { $0.trim() }
        reconcile()
    }

    public var statistics: Statistics {
        reconcile()
        let state = ledger.state.withLock { $0 }
        return Statistics(
            capacity: capacity,
            allocations: state.allocations,
            checkouts: state.checkouts,
            exhaustedCheckouts: state.exhaustedCheckouts,
            discarded: state.discarded,
            liveTextures: state.slots.count,
            texturesInUse: state.slots.filter(\.inUse).count,
            liveBytes: textures.values.reduce(0) { $0 + $1.storage.allocatedSize }
        )
    }

    /// Drops the pool's references to textures the ledger discarded.
    private func reconcile() {
        let live = ledger.state.withLock { Set($0.slots.map(\.id)) }
        if textures.count != live.count || !textures.keys.allSatisfy(live.contains) {
            textures = textures.filter { live.contains($0.key) }
        }
    }

    private func makeTexture(id: Int, width: Int, height: Int) -> PooledTexture? {
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: descriptor.pixelFormat, width: width, height: height, mipmapped: false
        )
        textureDescriptor.usage = descriptor.usage
        textureDescriptor.storageMode = descriptor.storageMode
        guard let storage = device.makeTexture(descriptor: textureDescriptor) else { return nil }
        storage.label = "GlassWeave pooled texture \(id)"
        if let sampledFormat = descriptor.sampledPixelFormat, sampledFormat != descriptor.pixelFormat {
            guard let view = storage.makeTextureView(pixelFormat: sampledFormat) else { return nil }
            return PooledTexture(id: id, storage: storage, texture: view)
        }
        return PooledTexture(id: id, storage: storage, texture: storage)
    }
}

/// One texture checked out of a ``FrameTexturePool``.
public struct PooledTexture {
    let id: Int
    /// The texture to write: render or blit into it.
    public let storage: any MTLTexture
    /// The texture to hand to consumers in a ``BackgroundFrame``: the
    /// storage itself, or a view of it in the pool's sampled format.
    public let texture: any MTLTexture
}

/// The ledger behind a reference both the pool and its leases share, so a
/// return after the pool is gone is still safe.
final class PoolLedgerBox: Sendable {
    let state: Mutex<TexturePoolLedger>

    init(capacity: Int) {
        state = Mutex(TexturePoolLedger(capacity: capacity))
    }
}

/// The pool's bookkeeping, separate from locking and from Metal so tests
/// can drive every transition directly.
struct TexturePoolLedger: Hashable, Sendable {
    struct Slot: Hashable, Sendable {
        let id: Int
        let width: Int
        let height: Int
        var inUse: Bool
        /// Discard instead of reusing when returned.
        var discardOnReturn: Bool
    }

    enum Checkout: Hashable, Sendable {
        case reuse(Int)
        case allocate(Int)
        case exhausted
    }

    let capacity: Int
    private(set) var slots: [Slot] = []
    private(set) var allocations = 0
    private(set) var checkouts = 0
    private(set) var exhaustedCheckouts = 0
    private(set) var discarded = 0
    private var nextID = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func checkout(width: Int, height: Int) -> Checkout {
        // Free textures of another size will not be used again.
        let before = slots.count
        slots.removeAll { !$0.inUse && ($0.width != width || $0.height != height) }
        discarded += before - slots.count
        // In-use textures of another size are discarded when they return.
        for index in slots.indices where slots[index].width != width || slots[index].height != height {
            slots[index].discardOnReturn = true
        }
        if let index = slots.firstIndex(where: { !$0.inUse && !$0.discardOnReturn }) {
            slots[index].inUse = true
            checkouts += 1
            return .reuse(slots[index].id)
        }
        guard slots.count < capacity else {
            exhaustedCheckouts += 1
            return .exhausted
        }
        let id = nextID
        nextID += 1
        slots.append(Slot(id: id, width: width, height: height, inUse: true, discardOnReturn: false))
        allocations += 1
        checkouts += 1
        return .allocate(id)
    }

    /// Metal could not create the texture for a new slot.
    mutating func allocationFailed(id: Int) {
        slots.removeAll { $0.id == id }
        allocations -= 1
        checkouts -= 1
    }

    /// A texture is free again. Unknown or already free IDs are ignored, so a
    /// return is idempotent.
    mutating func didReturn(id: Int) {
        guard let index = slots.firstIndex(where: { $0.id == id }), slots[index].inUse else { return }
        if slots[index].discardOnReturn {
            slots.remove(at: index)
            discarded += 1
        } else {
            slots[index].inUse = false
        }
    }

    mutating func trim() {
        let before = slots.count
        slots.removeAll { !$0.inUse }
        discarded += before - slots.count
        for index in slots.indices {
            slots[index].discardOnReturn = true
        }
    }
}
