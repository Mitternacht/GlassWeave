import CoreGraphics
import Metal
import os
internal import GlassWeaveShaderTypes

/// The numbers of a frost pyramid: how many levels, how large, how much
/// memory, and how much each level blurs. Pure arithmetic, no GPU.
///
/// A pyramid is one mipmapped `rgba16Float` texture in destination space.
/// Level 0 is half the resolution of the destination, each later level half
/// of the one before, down to 1/16 (four levels) or 1/32 (five). Every level
/// covers the same rectangle, so one normalized coordinate addresses all of
/// them. Level 0's size is rounded up to a multiple of `2^(levels - 1)`
/// texels, so every level is exactly half the one before and a texel of level
/// L is exactly `2^(L+1)` destination pixels wide.
enum FrostPyramidGeometry {
    static let minimumLevelCount = 4
    static let maximumLevelCount = 5
    /// The largest level-0 width or height, in texels: 16384 destination
    /// pixels, the largest 2D texture any Apple GPU makes.
    static let maximumLevel0Size = 8192
    /// Bytes per texel of `rgba16Float`.
    static let bytesPerTexel = 8

    /// The blur standard deviation, in destination pixels, of the filtered
    /// image at `level`: the square root of `1.75 * (4^(level+1) - 1) / 3`.
    /// Each level is a 13-tap downsample (variance 1.75 input texels) of the
    /// one before. 1.32, 2.96, 6.06, 12.2 and 24.4 pixels.
    static func levelSigma(_ level: Int) -> Float {
        Float((1.75 * (pow4(level + 1) - 1) / 3).squareRoot())
    }

    private static func pow4(_ exponent: Int) -> Double {
        Double(1 << (2 * exponent))
    }

    /// The levels a blur of `sigma` pixels needs: four, or five above the
    /// fourth level's blur.
    static func levelCount(forSigma sigma: Float) -> Int {
        sigma <= levelSigma(minimumLevelCount - 1) ? minimumLevelCount : maximumLevelCount
    }
}

/// Where a pyramid sits and how large it is: a region of the destination, in
/// pixels, and a level count. Equal plans give interchangeable textures.
struct FrostPyramidPlan: Hashable {
    /// The destination rectangle the pyramid must cover, in pixels (the
    /// origin may be negative: the region can extend past the target, where
    /// the source continues or its valid rectangle clamps).
    let region: PixelRect
    let levelCount: Int
    /// Level 0's size in texels.
    let level0Width: Int
    let level0Height: Int

    /// - Returns: `nil` for an empty region or one too large for a texture.
    init?(region: PixelRect, levelCount: Int) {
        guard region.width > 0, region.height > 0,
              (FrostPyramidGeometry.minimumLevelCount...FrostPyramidGeometry.maximumLevelCount).contains(levelCount)
        else { return nil }
        let alignment = 1 << (levelCount - 1)
        func level0(_ pixels: Int) -> Int {
            let half = (pixels + 1) / 2
            return (half + alignment - 1) / alignment * alignment
        }
        let width = level0(region.width)
        let height = level0(region.height)
        guard width <= FrostPyramidGeometry.maximumLevel0Size, height <= FrostPyramidGeometry.maximumLevel0Size else { return nil }
        self.region = region
        self.levelCount = levelCount
        level0Width = width
        level0Height = height
    }

    /// Texels of `level`.
    func size(ofLevel level: Int) -> (width: Int, height: Int) {
        (level0Width >> level, level0Height >> level)
    }

    /// The bytes the texture occupies: every level's texels at 8 bytes.
    var memoryBytes: Int {
        (0..<levelCount).reduce(0) { total, level in
            let size = size(ofLevel: level)
            return total + size.width * size.height * FrostPyramidGeometry.bytesPerTexel
        }
    }

    /// What the shader reads: where the pyramid is and how many levels it has.
    var layout: GWFrostPyramidLayout {
        GWFrostPyramidLayout(
            regionOrigin: SIMD2(Float(region.x), Float(region.y)),
            coverSize: SIMD2(Float(level0Width * 2), Float(level0Height * 2)),
            levelCount: UInt32(levelCount), padding0: 0
        )
    }

    /// Whether a texture made for `other` can hold this plan's levels.
    func sharesTexture(with other: FrostPyramidPlan) -> Bool {
        level0Width == other.level0Width && level0Height == other.level0Height && levelCount == other.levelCount
    }
}

/// A request for filtered backgrounds, in the units the app thinks in. The
/// renderer turns it into a plan for each draw.
///
/// **Experimental** (GW-24a): the later wiring replaces this single
/// renderer-wide request with each panel's own frost.
struct FrostRequest: Equatable, Sendable {
    /// The frost, normalized. The pyramid is built only if it is not none.
    var frost: GlassFrost
    /// The frosted area in points (origin top-left of the surface), or `nil`
    /// for the whole target.
    var region: CGRect?
    /// Extra reach beyond 3 sigma, in points (for example the largest
    /// refraction offset), added to the region on every side.
    var margin: Double = 0

    /// The pyramid this request needs for a draw at `displayScale` into a
    /// target of `targetSize` pixels, or `nil` when there is nothing to
    /// filter (no frost, or the region is off the target).
    ///
    /// An explicit region is clipped to the target, then grown by
    /// `3 * sigma + margin` so the blur's taps stay inside the pyramid.
    func plan(displayScale: Double, targetSize: (width: Int, height: Int)) -> FrostPyramidPlan? {
        guard !frost.isNone, displayScale > 0, displayScale.isFinite else { return nil }
        let sigma = Float(frost.sigma * displayScale)
        let levelCount = FrostPyramidGeometry.levelCount(forSigma: sigma)
        let target = CGRect(x: 0, y: 0, width: targetSize.width, height: targetSize.height)
        guard let region else {
            return FrostPyramidPlan(
                region: PixelRect(x: 0, y: 0, width: targetSize.width, height: targetSize.height),
                levelCount: levelCount
            )
        }
        let pixels = CGRect(
            x: region.minX * displayScale, y: region.minY * displayScale,
            width: region.width * displayScale, height: region.height * displayScale
        ).intersection(target)
        guard !pixels.isNull, pixels.width > 0, pixels.height > 0 else { return nil }
        let grow = (3 * Double(sigma) + margin * displayScale).rounded(.up)
        let minX = Int((pixels.minX - grow).rounded(.down))
        let minY = Int((pixels.minY - grow).rounded(.down))
        let maxX = Int((pixels.maxX + grow).rounded(.up))
        let maxY = Int((pixels.maxY + grow).rounded(.up))
        return FrostPyramidPlan(
            region: PixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            levelCount: levelCount
        )
    }
}

/// What the cache is keyed by: the source frame, the pyramid's region and
/// levels (the maximum blur enters through the levels it needs, so an
/// animated blur rebuilds only when it crosses a level step), and the target
/// size the destination mapping depends on.
struct FrostCacheKey: Hashable {
    let frameID: UInt64
    let plan: FrostPyramidPlan
    let targetWidth: Int
    let targetHeight: Int
}

/// A built pyramid, as the shader and the probe read it.
///
/// **Experimental** (GW-24a).
struct FrostPyramid {
    let texture: any MTLTexture
    let plan: FrostPyramidPlan
    fileprivate let levelViews: [any MTLTexture]

    var layout: GWFrostPyramidLayout { plan.layout }
}

/// The renderer-owned ring of up to ``capacity`` pyramids, the pipelines that
/// build them, and the cache that decides whether a draw builds, reuses or
/// takes a skip.
///
/// A pyramid is *in flight* from the moment a draw encodes work that reads it
/// until that draw's command buffer completes. A pyramid in flight is never
/// written: a build takes a free pyramid (none in flight) and a draw that
/// finds none takes the skip ``BackgroundRenderSkipReason/frostUnavailable``
/// instead of waiting. Completion handlers run on Metal's threads; they only
/// release the pyramid, under the lock.
///
/// Reuse needs no free pyramid: a draw whose key matches a built pyramid
/// reads it again (the earlier build is ahead of it on the same queue).
///
/// The renderer calls the ring from one isolation domain at a time, like
/// the renderer itself.
final class FrostPyramidRing: @unchecked Sendable {
    /// Pyramids that may exist at once.
    static let capacity = 3

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    private let sourcePipeline: any MTLComputePipelineState
    private let levelPipeline: any MTLComputePipelineState
    private let library: any MTLLibrary

    struct Counters: Equatable {
        /// Pyramids built.
        var builds = 0
        /// Draws that read a pyramid that was already built.
        var reuses = 0
        /// Pyramid textures allocated (the first of each size, and every
        /// change of size). Steady-state draws allocate none.
        var allocations = 0
    }

    private struct Slot {
        var pyramid: FrostPyramid?
        /// What the pyramid's texels hold; `nil` when invalid.
        var key: FrostCacheKey?
        /// Command buffers that read or write the pyramid and have not
        /// completed.
        var inFlight = 0
        var lastUsed: UInt64 = 0
    }

    private struct State {
        var slots = [Slot](repeating: Slot(), count: FrostPyramidRing.capacity)
        var counters = Counters()
        var tick: UInt64 = 0
        /// The pyramid the latest draw encoded work for.
        var current: FrostPyramid?
        var probePipeline: (any MTLComputePipelineState)?
        var atlasPipeline: (any MTLComputePipelineState)?
    }

    /// Metal objects are not `Sendable`, so the unchecked lock variant guards them;
    /// every access is under the lock.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(commandQueue: any MTLCommandQueue, library: any MTLLibrary) throws {
        device = commandQueue.device
        queue = commandQueue
        self.library = library
        sourcePipeline = try Self.makePipeline(device: device, library: library, name: "gw_frost_downsample_source")
        levelPipeline = try Self.makePipeline(device: device, library: library, name: "gw_frost_downsample_level")
    }

    private static func makePipeline(device: any MTLDevice, library: any MTLLibrary, name: String) throws -> any MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw BackgroundRendererError.missingShaderFunction(name)
        }
        do {
            return try device.makeComputePipelineState(function: function)
        } catch {
            throw BackgroundRendererError.pipelineCreationFailed("\(name): \(error)")
        }
    }

    // MARK: Observation

    var counters: Counters { state.withLockUnchecked { $0.counters } }

    /// The bytes of the pyramids the ring owns: each pyramid's computed
    /// size (every level at 8 bytes a texel), not what the device reports,
    /// because the iOS Simulator reports no allocation sizes.
    var memoryBytes: Int {
        state.withLockUnchecked { state in state.slots.reduce(0) { $0 + ($1.pyramid?.plan.memoryBytes ?? 0) } }
    }

    /// The pyramid the latest draw encoded (or reused), until it is trimmed.
    var current: FrostPyramid? { state.withLockUnchecked { $0.current } }

    // MARK: Draw path

    /// Whether a draw with `key` can be served without waiting: a built
    /// pyramid matches, or one is free. Called before the target is
    /// acquired.
    func canServe(_ key: FrostCacheKey) -> Bool {
        state.withLockUnchecked { state in
            Self.reusableSlot(in: state, key) != nil || Self.buildSlot(in: state, key.plan) != nil
        }
    }

    private static func reusableSlot(in state: State, _ key: FrostCacheKey) -> Int? {
        state.slots.firstIndex { $0.key == key && $0.pyramid != nil }
    }

    /// The pyramid a build for `plan` may write, best first: a free pyramid
    /// whose texture already fits, an empty one, then the least recently
    /// used free one of another size. `nil` when every pyramid is in flight.
    private static func buildSlot(in state: State, _ plan: FrostPyramidPlan) -> Int? {
        let free = state.slots.indices.filter { state.slots[$0].inFlight == 0 }
        if let fits = free.filter({ state.slots[$0].pyramid?.plan.sharesTexture(with: plan) == true })
            .min(by: { state.slots[$0].lastUsed < state.slots[$1].lastUsed }) {
            return fits
        }
        if let empty = free.first(where: { state.slots[$0].pyramid == nil }) {
            return empty
        }
        return free.min { state.slots[$0].lastUsed < state.slots[$1].lastUsed }
    }

    /// Encodes the pyramid for `key` into `commandBuffer`, before the render
    /// pass that reads it, and keeps it in flight until the command buffer
    /// completes. Builds it, or reuses the built one and encodes nothing.
    ///
    /// The source frame's writes are ordered before the build by the command
    /// buffer: a produced frame encoded earlier in it is sampled here, later.
    ///
    /// - Returns: `false` if no pyramid is free (the caller took
    ///   ``canServe(_:)`` first, so this is a compute encoder failure); then
    ///   nothing was encoded and nothing is in flight. When `true`, the
    ///   command buffer must be committed, or the pyramid stays in flight.
    func encode(
        key: FrostCacheKey, frame: BackgroundFrame, source: GWBackgroundUniforms,
        into commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        enum Plan { case reuse(Int, FrostPyramid), build(Int, FrostPyramid) }
        let chosen: Plan? = state.withLockUnchecked { state in
            state.tick += 1
            if let index = Self.reusableSlot(in: state, key), let pyramid = state.slots[index].pyramid {
                state.slots[index].inFlight += 1
                state.slots[index].lastUsed = state.tick
                state.counters.reuses += 1
                state.current = pyramid
                return .reuse(index, pyramid)
            }
            guard let index = Self.buildSlot(in: state, key.plan) else { return nil }
            if state.slots[index].pyramid?.plan.sharesTexture(with: key.plan) != true {
                guard let pyramid = makePyramid(key.plan) else { return nil }
                state.slots[index].pyramid = pyramid
                state.counters.allocations += 1
            }
            guard let existing = state.slots[index].pyramid else { return nil }
            // The texture is the same object; its plan carries the new region.
            let pyramid = FrostPyramid(texture: existing.texture, plan: key.plan, levelViews: existing.levelViews)
            state.slots[index].pyramid = pyramid
            state.slots[index].key = nil
            state.slots[index].inFlight += 1
            state.slots[index].lastUsed = state.tick
            return .build(index, pyramid)
        }
        guard let chosen else { return false }

        switch chosen {
        case let .reuse(index, _):
            commandBuffer.addCompletedHandler { [self] _ in release(index, built: nil, status: .completed) }
        case let .build(index, pyramid):
            guard encodeBuild(pyramid, key: key, frame: frame, source: source, into: commandBuffer) else {
                release(index, built: nil, status: .error)
                return false
            }
            state.withLockUnchecked { state in
                state.slots[index].key = key
                state.counters.builds += 1
                state.current = pyramid
            }
            commandBuffer.addCompletedHandler { [self] buffer in release(index, built: key, status: buffer.status) }
        }
        return true
    }

    /// Ends one command buffer's use of a pyramid. A build that did not
    /// complete leaves undefined texels, so its key is dropped.
    private func release(_ index: Int, built: FrostCacheKey?, status: MTLCommandBufferStatus) {
        state.withLockUnchecked { state in
            state.slots[index].inFlight -= 1
            if status != .completed, let built, state.slots[index].key == built {
                state.slots[index].key = nil
            }
        }
    }

    /// Releases the pyramids the ring owns, for a host that is hidden.
    ///
    /// Command buffers in flight keep their texture alive until they
    /// complete; the ring forgets it now, so a pyramid is built again when
    /// the surface draws next. Nothing is allocated meanwhile.
    func trim() {
        state.withLockUnchecked { state in
            for index in state.slots.indices {
                state.slots[index].pyramid = nil
                state.slots[index].key = nil
            }
            state.current = nil
        }
    }

    // MARK: Building

    private func makePyramid(_ plan: FrostPyramidPlan) -> FrostPyramid? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: plan.level0Width, height: plan.level0Height, mipmapped: true
        )
        descriptor.mipmapLevelCount = plan.levelCount
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "GlassWeave frost pyramid"
        var views: [any MTLTexture] = []
        for level in 0..<plan.levelCount {
            guard let view = texture.makeTextureView(
                pixelFormat: .rgba16Float, textureType: .type2D, levels: level..<(level + 1), slices: 0..<1
            ) else { return nil }
            view.label = "GlassWeave frost level \(level)"
            views.append(view)
        }
        return FrostPyramid(texture: texture, plan: plan, levelViews: views)
    }

    /// Dispatches whole 8 x 8 threadgroups that cover `width` x `height`
    /// texels. The kernels return early past the edge: non-uniform
    /// threadgroups (`dispatchThreads`) are not supported on every device, the
    /// iOS Simulator's among them.
    private static func dispatch(_ encoder: any MTLComputeCommandEncoder, width: Int, height: Int) {
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )
    }

    private func encodeBuild(
        _ pyramid: FrostPyramid, key: FrostCacheKey, frame: BackgroundFrame, source: GWBackgroundUniforms,
        into commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        let plan = pyramid.plan
        // One compute encoder per level: the encoder boundary orders the
        // writes of a level before the reads of the next (the textures are
        // hazard tracked), without `memoryBarrier`, which the iOS Simulator's
        // device does not support.
        for level in 0..<plan.levelCount {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
            encoder.label = "GlassWeave frost level \(level)"
            let output = plan.size(ofLevel: level)
            var uniforms = GWFrostBuildUniforms(
                uvFromDestinationX: source.uvFromDestinationX, uvFromDestinationY: source.uvFromDestinationY,
                uvOrigin: source.uvOrigin, sampleClampMin: source.sampleClampMin, sampleClampMax: source.sampleClampMax,
                regionOrigin: SIMD2(Float(plan.region.x), Float(plan.region.y)),
                targetSize: SIMD2(Float(key.targetWidth), Float(key.targetHeight)),
                outputSize: SIMD2(UInt32(output.width), UInt32(output.height)),
                inputTexelSize: .zero,
                outputSpacing: Float(2 << level),
                level: UInt32(level)
            )
            if level == 0 {
                encoder.setComputePipelineState(sourcePipeline)
                encoder.setTexture(frame.texture, index: Int(GWFrostBindingIndexInput.rawValue))
            } else {
                let input = plan.size(ofLevel: level - 1)
                uniforms.inputTexelSize = SIMD2(1 / Float(input.width), 1 / Float(input.height))
                encoder.setComputePipelineState(levelPipeline)
                encoder.setTexture(pyramid.levelViews[level - 1], index: Int(GWFrostBindingIndexInput.rawValue))
            }
            encoder.setTexture(pyramid.levelViews[level], index: Int(GWFrostBindingIndexOutput.rawValue))
            encoder.setBytes(&uniforms, length: MemoryLayout<GWFrostBuildUniforms>.stride, index: Int(GWFrostBindingIndexUniforms.rawValue))
            Self.dispatch(encoder, width: output.width, height: output.height)
            encoder.endEncoding()
        }
        return true
    }

    // MARK: Probe and atlas (tests and the laboratory)

    private func pipeline(_ name: String, cached: WritableKeyPath<State, (any MTLComputePipelineState)?>) -> (any MTLComputePipelineState)? {
        if let existing = state.withLockUnchecked({ $0[keyPath: cached] }) { return existing }
        guard let made = try? Self.makePipeline(device: device, library: library, name: name) else { return nil }
        state.withLockUnchecked { $0[keyPath: cached] = made }
        return made
    }

    /// Reads the filtered image at destination-pixel positions and levels of
    /// detail with the same function the glass shader will use, in linear
    /// light. Suspends until the GPU finishes; blocks no thread. For tests
    /// and tools: never called by a draw.
    ///
    /// The pyramid is read in a command buffer of its own on the renderer's
    /// queue, so it sees the build that is ahead of it there.
    func probe(_ pyramid: FrostPyramid, points: [(position: SIMD2<Float>, lod: Float)]) async -> [SIMD3<Float>] {
        guard !points.isEmpty, let pipeline = pipeline("gw_frost_probe", cached: \.probePipeline) else { return [] }
        var records = points.map { GWFrostProbePoint(position: $0.position, lod: $0.lod, padding0: 0) }
        var uniforms = GWFrostProbeUniforms(layout: pyramid.layout, pointCount: UInt32(points.count), padding0: 0)
        let count = points.count
        guard let pointBuffer = device.makeBuffer(bytes: &records, length: MemoryLayout<GWFrostProbePoint>.stride * count, options: .storageModeShared),
              let resultBuffer = device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * count, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return [] }
        commandBuffer.label = "GlassWeave frost probe"
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&uniforms, length: MemoryLayout<GWFrostProbeUniforms>.stride, index: Int(GWFrostBindingIndexUniforms.rawValue))
        encoder.setBuffer(pointBuffer, offset: 0, index: Int(GWFrostBindingIndexPoints.rawValue))
        encoder.setBuffer(resultBuffer, offset: 0, index: Int(GWFrostBindingIndexResults.rawValue))
        encoder.setTexture(pyramid.texture, index: Int(GWFrostBindingIndexInput.rawValue))
        encoder.dispatchThreadgroups(
            MTLSize(width: (count + 63) / 64, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1)
        )
        encoder.endEncoding()
        nonisolated(unsafe) let results = resultBuffer
        return await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { buffer in
                guard buffer.status == .completed else {
                    continuation.resume(returning: [])
                    return
                }
                let values = results.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
                continuation.resume(returning: (0..<count).map { SIMD3(values[$0].x, values[$0].y, values[$0].z) })
            }
            commandBuffer.commit()
        }
    }

    /// One image of the pyramid for the laboratory: a tile for each level,
    /// then a tile for each frost profile showing its blur radius. Suspends
    /// until the GPU finishes.
    nonisolated(nonsending) func atlasImage(_ pyramid: FrostPyramid, frost: GlassFrost, tileHeight: Int, columns: Int) async -> CGImage? {
        guard tileHeight > 0, columns > 0, let pipeline = pipeline("gw_frost_atlas", cached: \.atlasPipeline) else { return nil }
        let layout = pyramid.layout
        let tileWidth = max(1, Int((Float(tileHeight) * layout.coverSize.x / layout.coverSize.y).rounded()))
        let profileTiles = GlassFrost.Profile.allCases.count
        let tiles = pyramid.plan.levelCount + profileTiles
        let rows = (tiles + columns - 1) / columns
        let width = tileWidth * columns
        let height = tileHeight * rows
        let capsuleHalf = SIMD2(Float(tileWidth) * 0.42, Float(tileHeight) * 0.3)
        var uniforms = GWFrostAtlasUniforms(
            profile: GWFrostProfileUniforms(
                panelCenter: SIMD2(Float(tileWidth), Float(tileHeight)) / 2, panelHalfSize: capsuleHalf,
                cornerRadius: capsuleHalf.y, sigma: 1, transition: Float(tileHeight) * 0.22,
                rampTop: Float(frost.rampTop), rampBottom: Float(frost.rampBottom), grain: 0,
                profile: 0, padding0: 0, layout: layout
            ),
            tileSize: SIMD2(UInt32(tileWidth), UInt32(tileHeight)),
            levelTiles: UInt32(pyramid.plan.levelCount), profileTiles: UInt32(profileTiles),
            columns: UInt32(columns), padding0: 0
        )
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderWrite]
        descriptor.storageMode = .private
        let bytesPerRow = width * 4
        guard let output = device.makeTexture(descriptor: descriptor),
              let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let compute = commandBuffer.makeComputeCommandEncoder()
        else { return nil }
        commandBuffer.label = "GlassWeave frost atlas"
        compute.setComputePipelineState(pipeline)
        compute.setBytes(&uniforms, length: MemoryLayout<GWFrostAtlasUniforms>.stride, index: Int(GWFrostBindingIndexUniforms.rawValue))
        compute.setTexture(pyramid.texture, index: Int(GWFrostBindingIndexInput.rawValue))
        compute.setTexture(output, index: Int(GWFrostBindingIndexOutput.rawValue))
        Self.dispatch(compute, width: width, height: height)
        compute.endEncoding()
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height
        )
        blit.endEncoding()
        nonisolated(unsafe) let pixels = buffer
        return await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { completed in
                guard completed.status == .completed else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = Data(bytes: pixels.contents(), count: bytesPerRow * height)
                guard let provider = CGDataProvider(data: data as CFData) else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = CGImage(
                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
                )
                continuation.resume(returning: image)
            }
            commandBuffer.commit()
        }
    }
}
