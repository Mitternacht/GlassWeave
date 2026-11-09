#if !targetEnvironment(simulator)
import Foundation
import Metal
import Synchronization
internal import GlassWeaveShaderTypes

// GW-11: a narrow, package-level Metal 4 submission experiment.
//
// Nothing here is public API and nothing here is used by `GlassSurfaceView`,
// `GlassRenderer.draw` or any shipped path. The conventional path
// (`MTLCommandQueue`) stays the default and is the defined fallback: this file
// does not exist for the iOS Simulator SDK, which declares no Metal 4 types,
// and a device without the Metal 4 family never builds a `Metal4Renderer`.
//
// Every Metal 4 symbol used below was checked against the Xcode 27.2 SDK
// headers (`Metal.framework/Headers/MTL4*.h`), type-checked with swiftc against
// the macOS SDK, and read against Apple's documentation; the decision record
// (`docs/decisions/metal-backend.md`) lists them.

/// Why a ``Metal4Renderer`` could not be made.
package enum Metal4RendererError: Error, CustomStringConvertible {
    case metal4Unavailable(String)
    case resourceUnavailable(String)

    package var description: String {
        switch self {
        case let .metal4Unavailable(reason): "Metal 4 is unavailable: \(reason)."
        case let .resourceUnavailable(what): "Metal could not create \(what)."
        }
    }
}

/// What one ``Metal4Renderer/submit(target:source:displayScale:produce:completion:)`` did.
package enum Metal4SubmitOutcome: Hashable, Sendable {
    /// Encoded and committed.
    case submitted
    /// Every frame slot is still in flight; nothing was encoded. The caller
    /// skips this tick, as the conventional surface does at its bound.
    case atFrameLimit
    /// The renderer's panels need something the experiment does not encode
    /// (see `GlassRenderer.metal4Plan`). Nothing was encoded: the caller draws
    /// with the conventional path, the defined fallback.
    case unsupportedPanels
    /// The target has zero pixels in a dimension.
    case zeroSizeTarget
    /// Metal could not make an encoder. The command buffer is closed empty.
    case encoderUnavailable
}

/// What one submitted frame cost, delivered when the GPU finishes it.
package struct Metal4FrameTiming: Sendable {
    /// CPU time from the start of the submit call to just before the commit,
    /// without the producer's own time: the counterpart of
    /// `RenderMetrics.Sample.encodeDuration`.
    package var encodeSeconds: Double
    /// CPU time inside the producer closure: `produceDuration`.
    package var produceSeconds: Double
    /// GPU execution time from the commit feedback, or `nil` if the device
    /// reported none (both times zero).
    package var gpuSeconds: Double?
    /// Whether the command buffer finished without an error.
    package var completed: Bool
    /// `MTLDevice.currentAllocatedSize` when the frame was committed.
    package var deviceAllocatedBytes: Int
}

/// Writes small per-frame records into the frame's slice of the shared
/// uniform ring and returns the GPU address a shader reads them at. Metal 4
/// has no `setBytes`: every constant block is a buffer address in an argument
/// table.
package final class Metal4Staging {
    private let buffer: any MTLBuffer
    private let base: Int
    private let capacity: Int
    private var cursor = 0

    /// Records start on this boundary (a conservative `constant` alignment).
    static let alignment = 256

    fileprivate init(buffer: any MTLBuffer, base: Int, capacity: Int) {
        self.buffer = buffer
        self.base = base
        self.capacity = capacity
    }

    fileprivate func reset() {
        cursor = 0
    }

    /// Copies `length` bytes into the ring and returns their GPU address, or
    /// `nil` if the frame's slice is full.
    package func address(copying bytes: UnsafeRawPointer, length: Int) -> MTLGPUAddress? {
        let start = (cursor + Self.alignment - 1) & ~(Self.alignment - 1)
        guard start + length <= capacity else { return nil }
        (buffer.contents() + base + start).copyMemory(from: bytes, byteCount: length)
        cursor = start + length
        return buffer.gpuAddress + UInt64(base + start)
    }
}

/// The frame slots' busy flags. Only this ledger crosses to the completion
/// handler's thread.
fileprivate final class Metal4SlotLedger: Sendable {
    private let busy: Mutex<[Bool]>

    init(slotCount: Int) {
        busy = Mutex(Array(repeating: false, count: slotCount))
    }

    func claim() -> Int? {
        busy.withLock { flags in
            guard let index = flags.firstIndex(of: false) else { return nil }
            flags[index] = true
            return index
        }
    }

    func release(_ index: Int) {
        busy.withLock { $0[index] = false }
    }

    var inFlight: Int {
        busy.withLock { $0.filter { $0 }.count }
    }
}

/// Encodes a ``GlassRenderer``'s draw with Metal 4: one command allocator, one
/// reusable command buffer and one argument table per frame slot, one
/// residency set for every resource, and `MTL4CommandQueue` submission with
/// commit feedback for GPU times.
///
/// It draws with the renderer's own pipeline states (built by
/// `MTLDevice.makeRenderPipelineState`, which the Metal 4 render encoder
/// accepts) and its own panel list, effect time and lights, so the two
/// backends encode the same shaders over the same records. It bypasses the
/// source-lease machinery: the caller hands over a texture, orders its own
/// writes (a producer closure runs in the same command buffer, behind a
/// barrier) and owns reuse. Experimental; package-level; no API commitment.
///
/// Use it from one isolation domain at a time. It never waits for the GPU.
package final class Metal4Renderer {
    package let device: any MTLDevice
    package let queue: any MTL4CommandQueue
    package let renderer: GlassRenderer

    /// Frame slots: how many frames may be in flight at once.
    package let slotCount: Int

    private struct Slot {
        let allocator: any MTL4CommandAllocator
        let commandBuffer: any MTL4CommandBuffer
        let table: any MTL4ArgumentTable
        let staging: Metal4Staging
        let pass: MTL4RenderPassDescriptor
    }

    private let slots: [Slot]
    private let ledger: Metal4SlotLedger
    private let residency: any MTLResidencySet
    private let uniformBuffer: any MTLBuffer
    private let sliceCapacity = 64 * 1024

    /// Bytes of one slice of the uniform ring: the budget of one frame's
    /// records (producer, background, up to eight panels).
    package var uniformSliceBytes: Int { sliceCapacity }

    /// Creates a Metal 4 submission layer over `renderer`.
    ///
    /// - Throws: ``Metal4RendererError`` if the renderer's device does not
    ///   report the Metal 4 family (``RenderCapabilities/supportsMetal4``) or
    ///   cannot make one of the objects.
    package init(renderer: GlassRenderer, slotCount: Int = 3) throws(Metal4RendererError) {
        let device = renderer.device
        let capabilities = RenderCapabilities(device: device)
        guard capabilities.submissionBackend(preferringMetal4: true) == .metal4 else {
            throw .metal4Unavailable("\(capabilities.deviceName) does not report the Metal 4 family")
        }
        self.device = device
        self.renderer = renderer
        self.slotCount = slotCount

        let queueDescriptor = MTL4CommandQueueDescriptor()
        queueDescriptor.label = "GlassWeave Metal 4 experiment"
        guard let queue = try? device.makeMTL4CommandQueue(descriptor: queueDescriptor) else {
            throw .resourceUnavailable("an MTL4CommandQueue")
        }
        self.queue = queue

        let ring = sliceCapacity * slotCount
        guard let uniformBuffer = device.makeBuffer(length: ring, options: .storageModeShared) else {
            throw .resourceUnavailable("the uniform ring (\(ring) bytes)")
        }
        uniformBuffer.label = "GlassWeave Metal 4 uniform ring"
        self.uniformBuffer = uniformBuffer

        let residencyDescriptor = MTLResidencySetDescriptor()
        residencyDescriptor.label = "GlassWeave Metal 4 residency"
        guard let residency = try? device.makeResidencySet(descriptor: residencyDescriptor) else {
            throw .resourceUnavailable("an MTLResidencySet")
        }
        residency.addAllocation(uniformBuffer)
        residency.commit()
        residency.requestResidency()
        queue.addResidencySet(residency)
        self.residency = residency

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        // The shaders bind at most buffer 0 and texture 0 on this path.
        tableDescriptor.maxBufferBindCount = 4
        tableDescriptor.maxTextureBindCount = 2
        tableDescriptor.label = "GlassWeave Metal 4 argument table"

        var made: [Slot] = []
        for index in 0..<slotCount {
            guard let allocator = device.makeCommandAllocator(),
                  let commandBuffer = device.makeCommandBuffer(),
                  let table = try? device.makeArgumentTable(descriptor: tableDescriptor)
            else { throw .resourceUnavailable("a command allocator, command buffer or argument table") }
            commandBuffer.label = "GlassWeave Metal 4 frame slot \(index)"
            let pass = MTL4RenderPassDescriptor()
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            made.append(Slot(
                allocator: allocator, commandBuffer: commandBuffer, table: table,
                staging: Metal4Staging(buffer: uniformBuffer, base: index * sliceCapacity, capacity: sliceCapacity),
                pass: pass
            ))
        }
        slots = made
        ledger = Metal4SlotLedger(slotCount: slotCount)
    }

    /// Frames committed and not yet finished by the GPU.
    package var framesInFlight: Int {
        ledger.inFlight
    }

    /// Adds resources every frame reads or writes (textures, buffers) to the
    /// residency set. Call before the first frame that uses them; Metal 4
    /// does not make resources resident on its own.
    package func makeResident(_ allocations: [any MTLAllocation]) {
        guard !allocations.isEmpty else { return }
        residency.addAllocations(allocations)
        residency.commit()
        residency.requestResidency()
    }

    /// The residency set's reported footprint, in bytes.
    package var residencySetBytes: Int {
        Int(residency.allocatedSize)
    }

    /// The command allocators' reported footprint, in bytes.
    package var allocatorBytes: Int {
        slots.reduce(0) { $0 + Int($1.allocator.allocatedSize()) }
    }

    /// The uniform ring's size, in bytes.
    package var uniformRingBytes: Int {
        uniformBuffer.length
    }

    /// Builds an argument table a producer can bind its own resources with.
    package func makeProducerTable(maxBuffers: Int, maxTextures: Int, label: String) throws(Metal4RendererError) -> any MTL4ArgumentTable {
        let descriptor = MTL4ArgumentTableDescriptor()
        descriptor.maxBufferBindCount = maxBuffers
        descriptor.maxTextureBindCount = maxTextures
        descriptor.label = label
        guard let table = try? device.makeArgumentTable(descriptor: descriptor) else {
            throw .resourceUnavailable("an argument table")
        }
        return table
    }

    /// Encodes and commits one frame: the producer's pass (if any), then the
    /// background and the renderer's panels in one render pass into `target`.
    ///
    /// - Parameters:
    ///   - target: The render target, in ``GlassRenderer/outputPixelFormat``,
    ///     already passed to ``makeResident(_:)``.
    ///   - source: The texture the background and panels sample: a
    ///     `bgra8Unorm_srgb` view of what the producer writes, whole texture
    ///     valid, upright, as in the conventional path's default frame.
    ///   - displayScale: Pixels per point, as for the conventional draw.
    ///   - produce: Encodes the producer's pass into the command buffer (and
    ///     may stage records), returning whether it encoded anything. The
    ///     consumer pass starts behind a barrier when it did.
    ///   - completion: Called on a Metal queue when the GPU finishes the
    ///     frame, with its timing.
    package func submit(
        target: any MTLTexture,
        source: any MTLTexture,
        displayScale: Double,
        produce: ((_ commandBuffer: any MTL4CommandBuffer, _ staging: Metal4Staging) -> Bool)? = nil,
        completion: (@Sendable (Metal4FrameTiming) -> Void)? = nil
    ) -> Metal4SubmitOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        guard target.width > 0, target.height > 0 else { return .zeroSizeTarget }
        let backgroundUniforms = SourceUVTransform(
            destinationWidth: target.width, destinationHeight: target.height,
            textureWidth: source.width, textureHeight: source.height,
            validRect: PixelRect(x: 0, y: 0, width: source.width, height: source.height),
            orientation: .up
        ).uniforms
        guard let plan = renderer.metal4Plan(
            backgroundUniforms: backgroundUniforms,
            targetWidth: target.width, targetHeight: target.height, displayScale: displayScale
        ) else { return .unsupportedPanels }
        guard let index = ledger.claim() else { return .atFrameLimit }
        let slot = slots[index]

        // The allocator's memory is reused only after the frame that last
        // used it has finished, which the ledger's claim guarantees.
        slot.allocator.reset()
        slot.staging.reset()
        slot.commandBuffer.beginCommandBuffer(allocator: slot.allocator)

        var producerSeconds = 0.0
        var produced = false
        if let produce {
            let producerStart = clock.now
            produced = produce(slot.commandBuffer, slot.staging)
            producerSeconds = Self.seconds(clock.now - producerStart)
        }

        slot.pass.colorAttachments[0].texture = target
        guard let encoder = slot.commandBuffer.makeRenderCommandEncoder(descriptor: slot.pass) else {
            slot.commandBuffer.endCommandBuffer()
            ledger.release(index)
            return .encoderUnavailable
        }
        encoder.label = "GlassWeave Metal 4 background and panels"
        if produced {
            // Metal 4 tracks no hazards. The producer's fragment writes must
            // finish before this pass's fragment reads, through the sampled
            // view of the same storage.
            encoder.barrier(afterQueueStages: .fragment, beforeStages: .fragment, visibilityOptions: [.device, .resourceAlias])
        }
        encoder.setArgumentTable(slot.table, stages: [.vertex, .fragment])
        slot.table.setTexture(source.gpuResourceID, index: Int(GWBackgroundBindingIndexSourceTexture.rawValue))

        var background = backgroundUniforms
        var complete = true
        if let address = slot.staging.address(copying: &background, length: MemoryLayout<GWBackgroundUniforms>.stride) {
            encoder.pushDebugGroup("GlassWeave background")
            encoder.setRenderPipelineState(plan.backgroundPipeline)
            slot.table.setAddress(address, index: Int(GWBackgroundBindingIndexUniforms.rawValue))
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.popDebugGroup()
        } else {
            complete = false
        }
        for panel in plan.panels where complete {
            var uniforms = panel.uniforms
            guard let address = slot.staging.address(copying: &uniforms, length: MemoryLayout<GWGlassUniforms>.stride) else {
                complete = false
                break
            }
            encoder.pushDebugGroup("GlassWeave glass panel")
            encoder.setRenderPipelineState(panel.pipeline)
            slot.table.setAddress(address, index: Int(GWGlassBindingIndexUniforms.rawValue))
            encoder.drawPrimitives(primitiveType: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.popDebugGroup()
        }
        encoder.endEncoding()
        slot.commandBuffer.endCommandBuffer()
        let encodeSeconds = Self.seconds(clock.now - start) - producerSeconds
        let allocated = device.currentAllocatedSize

        let ledger = ledger
        let producedSeconds = producerSeconds
        let finished = complete
        let options = MTL4CommitOptions()
        options.addFeedbackHandler { feedback in
            let begin = feedback.gpuStartTime
            let end = feedback.gpuEndTime
            let timing = Metal4FrameTiming(
                encodeSeconds: encodeSeconds, produceSeconds: producedSeconds,
                gpuSeconds: begin == 0 && end == 0 ? nil : end - begin,
                completed: feedback.error == nil && finished,
                deviceAllocatedBytes: allocated
            )
            ledger.release(index)
            completion?(timing)
        }
        queue.commit([slot.commandBuffer], options: options)
        return .submitted
    }

    fileprivate static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }
}

// MARK: Conventional control arm

/// The same plan as ``Metal4Renderer``, submitted with conventional Metal
/// (`MTLCommandQueue`, `setFragmentBytes`, tracked hazards) and without the
/// source-lease machinery: the control that separates what the *API* costs
/// from what `GlassRenderer.drawProducing`'s validation and leases cost. The
/// shipped path is `GlassRenderer.draw`/`drawProducing`; this type is
/// measurement code and no host uses it. Experimental; package-level.
package final class ConventionalPlanRenderer {
    package let renderer: GlassRenderer
    package let slotCount: Int
    private let ledger: Metal4SlotLedger

    package init(renderer: GlassRenderer, slotCount: Int = 3) {
        self.renderer = renderer
        self.slotCount = slotCount
        ledger = Metal4SlotLedger(slotCount: slotCount)
    }

    /// Frames committed and not yet finished by the GPU.
    package var framesInFlight: Int {
        ledger.inFlight
    }

    /// Encodes and commits one frame like
    /// ``Metal4Renderer/submit(target:source:displayScale:produce:completion:)``:
    /// the producer's pass in the same command buffer, then the background and
    /// panels in one render pass into `target`. The producer closure encodes
    /// into a conventional command buffer; Metal orders its writes before the
    /// consumer's reads through hazard tracking.
    package func submit(
        target: any MTLTexture,
        source: any MTLTexture,
        displayScale: Double,
        produce: ((_ commandBuffer: any MTLCommandBuffer) -> Bool)? = nil,
        completion: (@Sendable (Metal4FrameTiming) -> Void)? = nil
    ) -> Metal4SubmitOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        guard target.width > 0, target.height > 0 else { return .zeroSizeTarget }
        let backgroundUniforms = SourceUVTransform(
            destinationWidth: target.width, destinationHeight: target.height,
            textureWidth: source.width, textureHeight: source.height,
            validRect: PixelRect(x: 0, y: 0, width: source.width, height: source.height),
            orientation: .up
        ).uniforms
        guard let plan = renderer.metal4Plan(
            backgroundUniforms: backgroundUniforms,
            targetWidth: target.width, targetHeight: target.height, displayScale: displayScale
        ) else { return .unsupportedPanels }
        guard let index = ledger.claim() else { return .atFrameLimit }
        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            ledger.release(index)
            return .encoderUnavailable
        }
        var producerSeconds = 0.0
        if let produce {
            let producerStart = clock.now
            _ = produce(commandBuffer)
            producerSeconds = Metal4Renderer.seconds(clock.now - producerStart)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            commandBuffer.commit()
            ledger.release(index)
            return .encoderUnavailable
        }
        encoder.label = "GlassWeave conventional control background and panels"
        var background = backgroundUniforms
        encoder.pushDebugGroup("GlassWeave background")
        encoder.setRenderPipelineState(plan.backgroundPipeline)
        encoder.setFragmentBytes(&background, length: MemoryLayout<GWBackgroundUniforms>.stride, index: Int(GWBackgroundBindingIndexUniforms.rawValue))
        encoder.setFragmentTexture(source, index: Int(GWBackgroundBindingIndexSourceTexture.rawValue))
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.popDebugGroup()
        let length = MemoryLayout<GWGlassUniforms>.stride
        let uniformsIndex = Int(GWGlassBindingIndexUniforms.rawValue)
        var textureSet = false
        for panel in plan.panels {
            var uniforms = panel.uniforms
            encoder.pushDebugGroup("GlassWeave glass panel")
            encoder.setRenderPipelineState(panel.pipeline)
            if !textureSet {
                encoder.setFragmentTexture(source, index: Int(GWGlassBindingIndexSourceTexture.rawValue))
                textureSet = true
            }
            encoder.setVertexBytes(&uniforms, length: length, index: uniformsIndex)
            encoder.setFragmentBytes(&uniforms, length: length, index: uniformsIndex)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.popDebugGroup()
        }
        encoder.endEncoding()
        let encodeSeconds = Metal4Renderer.seconds(clock.now - start) - producerSeconds
        let allocated = renderer.device.currentAllocatedSize
        let ledger = ledger
        let producedSeconds = producerSeconds
        commandBuffer.addCompletedHandler { finished in
            let begin = finished.gpuStartTime
            let end = finished.gpuEndTime
            let timing = Metal4FrameTiming(
                encodeSeconds: encodeSeconds, produceSeconds: producedSeconds,
                gpuSeconds: begin == 0 && end == 0 ? nil : end - begin,
                completed: finished.status == .completed, deviceAllocatedBytes: allocated
            )
            ledger.release(index)
            completion?(timing)
        }
        commandBuffer.commit()
        return .submitted
    }
}

// MARK: Pipeline compilation

/// One timed pipeline creation: which API, which pipeline, and where it fell
/// in the sequence (a shader cache makes a repeat of an identical pipeline
/// cheaper, and the process may have built it already).
package struct Metal4PipelineCompileSample: Sendable {
    package enum API: String, Sendable { case conventional, metal4Compiler }
    package var api: API
    package var label: String
    /// The position of this creation among all creations of this pipeline by
    /// either API in this call: 0 for the first, 1 for the second, and so on.
    package var sequenceIndex: Int
    package var seconds: Double
}

extension Metal4Renderer {
    /// Creates the base and optics glass panel pipelines through the
    /// conventional descriptor API and through `MTL4Compiler`, alternating
    /// which goes first for each pipeline, `repeats` times, and times each.
    ///
    /// Both build the same functions with the same function constants and the
    /// same color attachment from the package's own shader library. This
    /// measures only pipeline compilation, once, outside any draw.
    package static func measurePipelineCompilation(device: any MTLDevice, repeats: Int = 2) throws -> [Metal4PipelineCompileSample] {
        let library = try BackgroundRenderer.makeLibrary(device: device)
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        let clock = ContinuousClock()
        let variants: [(label: String, optics: Bool)] = [("panel base", false), ("panel optics", true)]
        var samples: [Metal4PipelineCompileSample] = []

        func constants(optics: Bool) -> MTLFunctionConstantValues {
            let values = MTLFunctionConstantValues()
            var optics = optics
            var off = false
            values.setConstantValue(&optics, type: .bool, index: 0)
            values.setConstantValue(&off, type: .bool, index: 1)
            values.setConstantValue(&off, type: .bool, index: 3)
            return values
        }

        func conventional(_ variant: (label: String, optics: Bool)) throws -> Double {
            let begin = clock.now
            let vertex = library.makeFunction(name: "gw_glass_vertex")
            let fragment = try library.makeFunction(name: "gw_glass_fragment", constantValues: constants(optics: variant.optics))
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = BackgroundRenderer.outputPixelFormat
            _ = try device.makeRenderPipelineState(descriptor: descriptor)
            return seconds(clock.now - begin)
        }

        func metal4(_ variant: (label: String, optics: Bool)) throws -> Double {
            let begin = clock.now
            let vertex = MTL4LibraryFunctionDescriptor()
            vertex.name = "gw_glass_vertex"
            vertex.library = library
            let fragmentBase = MTL4LibraryFunctionDescriptor()
            fragmentBase.name = "gw_glass_fragment"
            fragmentBase.library = library
            let fragment = MTL4SpecializedFunctionDescriptor()
            fragment.functionDescriptor = fragmentBase
            fragment.constantValues = constants(optics: variant.optics)
            let descriptor = MTL4RenderPipelineDescriptor()
            descriptor.vertexFunctionDescriptor = vertex
            descriptor.fragmentFunctionDescriptor = fragment
            descriptor.colorAttachments[0].pixelFormat = BackgroundRenderer.outputPixelFormat
            _ = try compiler.makeRenderPipelineState(descriptor: descriptor, compilerTaskOptions: nil)
            return seconds(clock.now - begin)
        }

        for (position, variant) in variants.enumerated() {
            // The first pipeline is made conventionally first, the second by
            // the Metal 4 compiler first.
            let conventionalFirst = position % 2 == 0
            for round in 0..<repeats {
                let order: [Metal4PipelineCompileSample.API] = (conventionalFirst == (round % 2 == 0))
                    ? [.conventional, .metal4Compiler] : [.metal4Compiler, .conventional]
                for api in order {
                    let seconds = api == .conventional ? try conventional(variant) : try metal4(variant)
                    let seen = samples.filter { $0.label == variant.label }.count
                    samples.append(Metal4PipelineCompileSample(api: api, label: variant.label, sequenceIndex: seen, seconds: seconds))
                }
            }
        }
        return samples
    }
}
#endif
