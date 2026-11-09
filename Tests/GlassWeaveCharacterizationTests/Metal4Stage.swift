#if !targetEnvironment(simulator)
import Foundation
import GlassWeave
import Metal
import Synchronization
import Testing

/// The laboratory's procedural background as a producer pass that can be
/// encoded either with conventional Metal or with Metal 4, with the same
/// pipeline state (a `MTLRenderPipelineState` made by `MTLDevice` is accepted
/// by both encoders) and the same five float parameters.
struct LabProducer {
    typealias Workload = CharacterizationTests.Workload

    let pipeline: any MTLRenderPipelineState

    init(device: any MTLDevice) throws {
        let library = try device.makeDefaultLibrary(bundle: .module)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Characterization procedural background"
        descriptor.vertexFunction = library.makeFunction(name: "lab_background_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "lab_background_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// The shader's parameters: content time, scale, frame ID, strip off.
    static func parameters(time: Double, frameID: UInt64) -> [Float] {
        [Float(time), Float(Workload.displayScale), Float(frameID % (1 << 24)), 0, 0]
    }

    /// The conventional encode: one render pass into `storage` with the
    /// parameters set as inline bytes.
    func encodeConventional(into commandBuffer: any MTLCommandBuffer, storage: any MTLTexture, parameters: [Float]) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = storage
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var parameters = parameters
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&parameters, length: parameters.count * MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    /// The Metal 4 encode: the same pass, with the parameters in the frame's
    /// uniform ring and bound through an argument table.
    func encodeMetal4(
        into commandBuffer: any MTL4CommandBuffer, storage: any MTLTexture, parameters: [Float],
        staging: Metal4Staging, table: any MTL4ArgumentTable, pass: MTL4RenderPassDescriptor
    ) -> Bool {
        var parameters = parameters
        guard let address = staging.address(copying: &parameters, length: parameters.count * MemoryLayout<Float>.stride) else {
            return false
        }
        pass.colorAttachments[0].texture = storage
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        encoder.setArgumentTable(table, stages: [.vertex, .fragment])
        table.setAddress(address, index: 0)
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }
}

/// Timings that completed since the last ``drain()``. A class so a
/// completion handler's `@Sendable` closure can hold it.
final class TimingCollector: Sendable {
    let timings = Mutex<[Metal4FrameTiming]>([])
    func append(_ timing: Metal4FrameTiming) { timings.withLock { $0.append(timing) } }
    func drain() -> [Metal4FrameTiming] { timings.withLock { let all = $0; $0 = []; return all } }
}

/// The textures of a Metal 4 stage: `count` producer storage textures with
/// the `bgra8Unorm_srgb` view GlassWeave samples, and `count` render targets.
struct Metal4Textures {
    let storage: [any MTLTexture]
    let sampled: [any MTLTexture]
    let targets: [any MTLTexture]

    init(device: any MTLDevice, size: (width: Int, height: Int), count: Int, targetStorage: MTLStorageMode = .private) throws {
        let storageDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false
        )
        storageDescriptor.usage = [.renderTarget, .shaderRead, .pixelFormatView]
        storageDescriptor.storageMode = .private
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: GlassRenderer.outputPixelFormat, width: size.width, height: size.height, mipmapped: false
        )
        targetDescriptor.usage = [.renderTarget]
        targetDescriptor.storageMode = targetStorage
        var storage: [any MTLTexture] = []
        var sampled: [any MTLTexture] = []
        var targets: [any MTLTexture] = []
        for index in 0..<count {
            let source = try #require(device.makeTexture(descriptor: storageDescriptor))
            source.label = "Metal 4 source \(index)"
            let view = try #require(source.makeTextureView(pixelFormat: BackgroundColorConvention.sRGBOpaque.requiredPixelFormat))
            view.label = "Metal 4 source view \(index)"
            let target = try #require(device.makeTexture(descriptor: targetDescriptor))
            target.label = "Metal 4 target \(index)"
            storage.append(source)
            sampled.append(view)
            targets.append(target)
        }
        self.storage = storage
        self.sampled = sampled
        self.targets = targets
    }

    var allocations: [any MTLAllocation] {
        storage + sampled + targets
    }
}

/// The Metal 4 counterpart of `OffscreenStage`: one `GlassRenderer`, a
/// `Metal4Renderer` over it, the laboratory's producer encoded with Metal 4,
/// and rings of three sources and three targets. Each tick advances effect
/// time and content time by one 60 Hz step and submits a frame unless two are
/// already in flight (the surface's bound), exactly the rule the conventional
/// stage follows through `FrameScheduler`.
final class Metal4Stage {
    typealias Workload = CharacterizationTests.Workload

    let device: any MTLDevice
    let renderer: GlassRenderer
    let metal4: Metal4Renderer
    let producer: LabProducer
    let textures: Metal4Textures
    private let producerTable: any MTL4ArgumentTable
    private let producerPass = MTL4RenderPassDescriptor()

    private let collector = TimingCollector()
    private(set) var ticks: UInt64 = 0
    private var nextFrameID: UInt64 = 1
    private var nextIndex = 0
    private(set) var submitted = 0
    private(set) var deferredAtBound = 0
    private(set) var unsupported = 0
    private(set) var otherSkips = 0

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "Characterization needs a Metal device")
        let queue = try #require(device.makeCommandQueue())
        queue.label = "GlassWeave Metal 4 characterization (renderer queue)"
        renderer = try GlassRenderer(commandQueue: queue)
        metal4 = try Metal4Renderer(renderer: renderer)
        producer = try LabProducer(device: device)
        textures = try Metal4Textures(device: device, size: Workload.portrait, count: Workload.renderTargets)
        producerTable = try metal4.makeProducerTable(maxBuffers: 1, maxTextures: 0, label: "Characterization producer table")
        metal4.makeResident(textures.allocations)
    }

    /// One display-link tick.
    func tick() {
        ticks += 1
        try? renderer.setEffectTime(Double(ticks) / Double(Workload.ticksPerSecond))
        guard metal4.framesInFlight < FrameStatistics.boundForCharacterization else {
            deferredAtBound += 1
            return
        }
        let index = nextIndex
        let frameID = nextFrameID
        let parameters = LabProducer.parameters(time: Double(ticks) / Double(Workload.ticksPerSecond), frameID: frameID)
        let producer = producer
        let storage = textures.storage[index]
        let table = producerTable
        let pass = producerPass
        let collector = collector
        let outcome = metal4.submit(
            target: textures.targets[index], source: textures.sampled[index], displayScale: Workload.displayScale,
            produce: { commandBuffer, staging in
                producer.encodeMetal4(
                    into: commandBuffer, storage: storage, parameters: parameters,
                    staging: staging, table: table, pass: pass
                )
            },
            completion: { collector.append($0) }
        )
        switch outcome {
        case .submitted:
            submitted += 1
            nextFrameID += 1
            nextIndex = (nextIndex + 1) % textures.targets.count
        case .atFrameLimit: deferredAtBound += 1
        case .unsupportedPanels: unsupported += 1
        case .zeroSizeTarget, .encoderUnavailable: otherSkips += 1
        }
    }

    /// Ticks at 60 Hz for `duration`; a late wake-up drops ticks. Returns the
    /// ticks that ran.
    @discardableResult
    func tick(for duration: Duration) async throws -> Int {
        let clock = ContinuousClock()
        let begin = clock.now
        var deadline = begin
        var count = 0
        while clock.now - begin < duration {
            tick()
            count += 1
            deadline = max(deadline + Workload.tickInterval, clock.now)
            try await clock.sleep(until: deadline, tolerance: .microseconds(500))
        }
        return count
    }

    /// Waits without blocking until no frame is in flight.
    func awaitIdle() async {
        let deadline = ContinuousClock.now + .seconds(10)
        while metal4.framesInFlight > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(metal4.framesInFlight == 0, "Metal 4 frames still in flight after 10 s")
    }

    /// The timings of frames that finished since the last call.
    func drain() -> [Metal4FrameTiming] {
        collector.drain()
    }

    func resetCounts() {
        submitted = 0
        deferredAtBound = 0
        unsupported = 0
        otherSkips = 0
    }
}
/// The control arm: the same plan, producer, textures and tick rule as
/// ``Metal4Stage``, submitted through conventional Metal and without the
/// source-lease machinery (``ConventionalPlanRenderer``). Comparing it with
/// ``Metal4Stage`` isolates the submission API; comparing it with
/// `OffscreenStage` (the shipped `GlassRenderer.drawProducing`) shows what
/// the lease machinery costs.
final class ConventionalRawStage {
    typealias Workload = CharacterizationTests.Workload

    let device: any MTLDevice
    let renderer: GlassRenderer
    let plan: ConventionalPlanRenderer
    let producer: LabProducer
    let textures: Metal4Textures
    private let collector = TimingCollector()
    private(set) var ticks: UInt64 = 0
    private var nextFrameID: UInt64 = 1
    private var nextIndex = 0
    private(set) var submitted = 0
    private(set) var deferredAtBound = 0
    private(set) var unsupported = 0
    private(set) var otherSkips = 0

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "Characterization needs a Metal device")
        let queue = try #require(device.makeCommandQueue())
        queue.label = "GlassWeave conventional control characterization"
        renderer = try GlassRenderer(commandQueue: queue)
        plan = ConventionalPlanRenderer(renderer: renderer)
        producer = try LabProducer(device: device)
        textures = try Metal4Textures(device: device, size: Workload.portrait, count: Workload.renderTargets)
    }

    func tick() {
        ticks += 1
        try? renderer.setEffectTime(Double(ticks) / Double(Workload.ticksPerSecond))
        guard plan.framesInFlight < FrameStatistics.boundForCharacterization else {
            deferredAtBound += 1
            return
        }
        let index = nextIndex
        let parameters = LabProducer.parameters(time: Double(ticks) / Double(Workload.ticksPerSecond), frameID: nextFrameID)
        let producer = producer
        let storage = textures.storage[index]
        let collector = collector
        let outcome = plan.submit(
            target: textures.targets[index], source: textures.sampled[index], displayScale: Workload.displayScale,
            produce: { commandBuffer in
                producer.encodeConventional(into: commandBuffer, storage: storage, parameters: parameters)
            },
            completion: { collector.append($0) }
        )
        switch outcome {
        case .submitted:
            submitted += 1
            nextFrameID += 1
            nextIndex = (nextIndex + 1) % textures.targets.count
        case .atFrameLimit: deferredAtBound += 1
        case .unsupportedPanels: unsupported += 1
        case .zeroSizeTarget, .encoderUnavailable: otherSkips += 1
        }
    }

    @discardableResult
    func tick(for duration: Duration) async throws -> Int {
        let clock = ContinuousClock()
        let begin = clock.now
        var deadline = begin
        var count = 0
        while clock.now - begin < duration {
            tick()
            count += 1
            deadline = max(deadline + Workload.tickInterval, clock.now)
            try await clock.sleep(until: deadline, tolerance: .microseconds(500))
        }
        return count
    }

    func awaitIdle() async {
        let deadline = ContinuousClock.now + .seconds(10)
        while plan.framesInFlight > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(plan.framesInFlight == 0, "Conventional control frames still in flight after 10 s")
    }

    func drain() -> [Metal4FrameTiming] {
        collector.drain()
    }

    func resetCounts() {
        submitted = 0
        deferredAtBound = 0
        unsupported = 0
        otherSkips = 0
    }
}
#endif
