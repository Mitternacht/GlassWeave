import Foundation
import GlassWeave
import Metal
import Synchronization
import Testing

/// GW-11: conventional Metal submission against the experimental Metal 4
/// path, on the fixed GW-09 workload rendered offscreen.
///
/// Two tests, both enabled only on a device that reports the Metal 4 family
/// (never the iOS Simulator, never an older GPU; those run the conventional
/// path alone, which is the defined fallback):
/// - the two paths render the reference cases and agree within one 8-bit step;
/// - a comparison harness that interleaves the paths and reports compilation,
///   CPU encode, GPU time, memory and steady-state behavior. Like
///   ``CharacterizationTests`` it takes its durations from the environment
///   (`GLASSWEAVE_CHARACTERIZATION_*`); unset, it is a short smoke run whose
///   timings are not data. The decision record's numbers come from a quiet
///   run of the GlassWeaveCharacterization scheme (Release, no validation).
///
/// No `@testable` import: everything used is public or package API.
@Suite(.serialized)
struct Metal4ComparisonTests {
    typealias Workload = CharacterizationTests.Workload

    static let skipReason: Comment = "The Metal 4 experiment runs only where the device reports the Metal 4 family; the iOS Simulator and older GPUs use the conventional path"

    /// Whether the system's default device reports the Metal 4 family and so
    /// selects the Metal 4 backend when asked.
    static var metal4Supported: Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return RenderCapabilities(device: device).submissionBackend(preferringMetal4: true) == .metal4
    }

    /// The reference lens panel: the workload's panel with a thick circular
    /// lens and dispersion, which draws in the optics pipeline variant.
    static let lensPanel: GlassPanel = {
        var panel = Workload.panel
        panel.parameters.lens = GlassLens(profile: .circular, thickness: 28, indexOfRefraction: 1.5, maximumOffset: 48, dispersion: 0.35)
        return panel
    }()

    /// A workload of the A/B harness: the GW-09 panel and the lens panel.
    enum Case: String, CaseIterable {
        case panel
        case lens

        var panel: GlassPanel {
            switch self {
            case .panel: Workload.panel
            case .lens: Metal4ComparisonTests.lensPanel
            }
        }
    }

    // MARK: Agreement

    #if !targetEnvironment(simulator)
    /// One reference image: its panel (or none), the effect time and the
    /// content time it was rendered at.
    struct Reference {
        let name: String
        let panel: GlassPanel?
        let effectTime: Double
        let expectedVariants: [GlassRenderer.PipelineVariant]
    }

    static let references: [Reference] = [
        Reference(name: "background only", panel: nil, effectTime: 0, expectedVariants: []),
        Reference(name: "one glass panel", panel: Workload.panel, effectTime: 0, expectedVariants: [.base]),
        Reference(name: "one lens panel", panel: lensPanel, effectTime: 0, expectedVariants: [.optics]),
        Reference(name: "glowing panel, pulse at 0.4 s", panel: Workload.glowPanel, effectTime: 0.4, expectedVariants: [.base]),
    ]

    #endif

    @Test(
        "The Metal 4 path and the conventional path agree within one 8-bit step",
        .enabled(if: Metal4ComparisonTests.metal4Supported, Metal4ComparisonTests.skipReason), .timeLimit(.minutes(5))
    )
    func backendsAgree() async throws {
        #if !targetEnvironment(simulator)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let producer = try LabProducer(device: device)
        let size = Workload.portrait
        let contentTime = 0.75
        var conventionalImages: [[UInt8]] = []

        for reference in Self.references {
            let conventional = try renderConventional(device: device, producer: producer, size: size, reference: reference, contentTime: contentTime)
            let metal4 = try await renderMetal4(device: device, producer: producer, size: size, reference: reference, contentTime: contentTime)
            #expect(conventional.count == metal4.count && conventional.count == size.width * size.height * 4)

            var maximum = 0
            var differing = 0
            for index in 0..<min(conventional.count, metal4.count) {
                let difference = abs(Int(conventional[index]) - Int(metal4[index]))
                maximum = max(maximum, difference)
                if difference > 0 { differing += 1 }
            }
            print("GW-11 agreement, \(reference.name): largest 8-bit difference \(maximum), \(differing) of \(conventional.count) bytes differ")
            #expect(maximum <= 1, "\(reference.name): the paths differ by up to \(maximum) in 8-bit steps (\(differing) of \(conventional.count) bytes differ)")
            conventionalImages.append(conventional)
        }

        // Guards against two paths that agree because both drew nothing: each
        // panel case must differ from the background-only picture somewhere.
        let background = conventionalImages[0]
        for (index, reference) in Self.references.enumerated().dropFirst() {
            let changed = zip(background, conventionalImages[index]).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
            #expect(changed > 1_000, "\(reference.name) drew (almost) nothing over the background: \(changed) bytes changed")
        }

        // The defined fallback for a panel the experiment does not encode: a
        // frosted panel needs a compute pre-pass, so the Metal 4 path declines
        // before it encodes anything and the caller draws conventionally.
        let renderer = try GlassRenderer(commandQueue: try #require(device.makeCommandQueue()))
        var frosted = Workload.panel
        frosted.parameters.frost = GlassFrost(profile: .uniform, sigma: 6)
        try renderer.setPanel(frosted)
        let metal4 = try Metal4Renderer(renderer: renderer)
        let textures = try Metal4Textures(device: device, size: size, count: 1)
        metal4.makeResident(textures.allocations)
        let declined = metal4.submit(target: textures.targets[0], source: textures.sampled[0], displayScale: Workload.displayScale)
        #expect(declined == .unsupportedPanels, "A frosted panel must fall back to the conventional path, got \(declined)")
        #expect(metal4.framesInFlight == 0, "A declined draw must not leave a frame in flight")
        #endif
    }

    #if !targetEnvironment(simulator)

    /// Renders `reference` with `GlassRenderer.drawProducing` and reads it back.
    private func renderConventional(
        device: any MTLDevice, producer: LabProducer, size: (width: Int, height: Int),
        reference: Reference, contentTime: Double
    ) throws -> [UInt8] {
        let queue = try #require(device.makeCommandQueue())
        let renderer = try GlassRenderer(commandQueue: queue)
        try renderer.setPanel(reference.panel)
        try renderer.setEffectTime(reference.effectTime)
        let pool = FrameTexturePool(
            device: device,
            descriptor: FrameTexturePool.Descriptor(
                pixelFormat: .bgra8Unorm, usage: [.renderTarget, .shaderRead, .pixelFormatView],
                sampledPixelFormat: BackgroundColorConvention.sRGBOpaque.requiredPixelFormat
            ),
            capacity: 1
        )
        let target = try Self.sharedTarget(device: device, size: size)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        var committed: (any MTLCommandBuffer)?
        let outcome = try renderer.drawProducing(
            targetPixelSize: size, displayScale: Workload.displayScale,
            produce: { commandBuffer, pixelSize in
                guard let pooled = pool.checkout(width: pixelSize.width, height: pixelSize.height),
                      producer.encodeConventional(
                        into: commandBuffer, storage: pooled.storage,
                        parameters: LabProducer.parameters(time: contentTime, frameID: 1)
                      )
                else { return nil }
                let frame = BackgroundFrame(
                    texture: pooled.texture, frameID: 1, timestamp: .zero,
                    colorConvention: .sRGBOpaque, readiness: .encoded(in: commandBuffer)
                )
                return pool.lease(frame, using: pooled) { _ in }
            },
            acquireTarget: { BackgroundDrawTarget(renderPassDescriptor: pass) },
            onCommit: { committed = $0 }
        )
        #expect(outcome == .submitted(frameID: 1), "\(reference.name): the conventional draw was not submitted: \(outcome)")
        #expect(renderer.drawnVariants == reference.expectedVariants, "\(reference.name): conventional variants \(renderer.drawnVariants)")
        committed?.waitUntilCompleted()
        #expect(committed?.status == .completed, "\(reference.name): the conventional command buffer did not complete")
        return Self.readBack(target)
    }

    /// The completion of the one frame an agreement render submits.
    private final class FinishedFrame: Sendable {
        let timing = Mutex<Metal4FrameTiming?>(nil)
    }

    /// Renders `reference` with the Metal 4 path and reads it back.
    private func renderMetal4(
        device: any MTLDevice, producer: LabProducer, size: (width: Int, height: Int),
        reference: Reference, contentTime: Double
    ) async throws -> [UInt8] {
        let queue = try #require(device.makeCommandQueue())
        let renderer = try GlassRenderer(commandQueue: queue)
        try renderer.setPanel(reference.panel)
        try renderer.setEffectTime(reference.effectTime)
        let metal4 = try Metal4Renderer(renderer: renderer)
        let textures = try Metal4Textures(device: device, size: size, count: 1, targetStorage: .shared)
        let table = try metal4.makeProducerTable(maxBuffers: 1, maxTextures: 0, label: "Agreement producer table")
        let pass = MTL4RenderPassDescriptor()
        metal4.makeResident(textures.allocations)
        let storage = textures.storage[0]
        let finished = FinishedFrame()
        let outcome = metal4.submit(
            target: textures.targets[0], source: textures.sampled[0], displayScale: Workload.displayScale,
            produce: { commandBuffer, staging in
                producer.encodeMetal4(
                    into: commandBuffer, storage: storage,
                    parameters: LabProducer.parameters(time: contentTime, frameID: 1),
                    staging: staging, table: table, pass: pass
                )
            },
            completion: { timing in finished.timing.withLock { $0 = timing } }
        )
        #expect(outcome == .submitted, "\(reference.name): the Metal 4 draw was not submitted: \(outcome)")
        let deadline = ContinuousClock.now + .seconds(10)
        while metal4.framesInFlight > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(metal4.framesInFlight == 0, "\(reference.name): the Metal 4 frame did not finish within 10 s")
        #expect(finished.timing.withLock { $0?.completed } == true, "\(reference.name): the Metal 4 command buffer did not complete cleanly")
        return Self.readBack(textures.targets[0])
    }

    private static func sharedTarget(device: any MTLDevice, size: (width: Int, height: Int)) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: GlassRenderer.outputPixelFormat, width: size.width, height: size.height, mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private static func readBack(_ texture: any MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return bytes
    }

    // MARK: Comparison harness

    /// One window of one backend on one workload.
    struct Window {
        /// The three arms. `conventional` is the shipped
        /// `GlassRenderer.drawProducing`; `conventionalRaw` is the control
        /// (the same plan through conventional Metal without the lease
        /// machinery); `metal4` is the experiment.
        enum Backend: String, CaseIterable { case conventional, conventionalRaw, metal4 }
        let backend: Backend
        let workload: Case
        let run: Int
        let ticks: Int
        let drawn: Int
        let deferredAtBound: Int
        let failed: Int
        let skipped: Int
        let gpu: [Duration]
        let encode: [Duration]
        let produce: [Duration]
        let allocatedBytes: [Int]
    }

    #endif

    @Test(
        "Metal 4 against conventional submission on the GW-09 workload, interleaved",
        .enabled(if: Metal4ComparisonTests.metal4Supported, Metal4ComparisonTests.skipReason), .timeLimit(.minutes(45))
    )
    func compareBackends() async throws {
        #if !targetEnvironment(simulator)
        let settings = CharacterizationTests.Settings.current
        let thermalStateAtStart = ProcessInfo.processInfo.thermalState
        let device = try #require(MTLCreateSystemDefaultDevice())

        // Pipeline compilation, outside any stage and first in the process
        // when this test runs alone: the same two glass pipelines through
        // each API, alternating which goes first.
        let renderersBeforeCompile = RendererCensus.created
        let compile = try Metal4Renderer.measurePipelineCompilation(device: device, repeats: 2)

        // Creation footprint of each path. Each path is created and dropped
        // once first so that library loading and driver warm-up are not
        // charged to whichever is measured first.
        _ = try await Self.footprintOfConventional()
        _ = try await Self.footprintOfRaw()
        _ = try await Self.footprintOfMetal4()
        let footprints = [
            try await Self.footprintOfConventional(),
            try await Self.footprintOfRaw(),
            try await Self.footprintOfMetal4(),
        ]

        let conventional = try OffscreenStage()
        let raw = try ConventionalRawStage()
        let metal4 = try Metal4Stage()
        var windows: [Window] = []

        for run in 1...settings.runs {
            for (position, workload) in Case.allCases.enumerated() {
                // Interleave: rotate which backend goes first, per run and per
                // case, so none always runs earlier or warmer.
                let backends = Window.Backend.allCases
                let shift = (run - 1 + position) % backends.count
                for backend in (0..<backends.count).map({ backends[($0 + shift) % backends.count] }) {
                    switch backend {
                    case .conventional:
                        windows.append(try await Self.measure(conventional, workload: workload, run: run, settings: settings))
                    case .conventionalRaw:
                        windows.append(try await Self.measure(raw, workload: workload, run: run, settings: settings))
                    case .metal4:
                        windows.append(try await Self.measure(metal4, workload: workload, run: run, settings: settings))
                    }
                }
            }
        }

        let report = Self.report(
            settings: settings, device: device, conventional: conventional, metal4: metal4, windows: windows,
            compile: compile, renderersBeforeCompile: renderersBeforeCompile, footprints: footprints,
            thermalStates: (thermalStateAtStart, ProcessInfo.processInfo.thermalState)
        )
        print(report)
        Attachment.record(report, named: "glassweave-metal4-comparison.txt")

        // Checks that hold on any Metal 4 device: the harness measured every
        // arm, nothing failed, and the experiment encoded every frame.
        for window in windows {
            #expect(window.drawn > 0, "\(window.backend) \(window.workload) run \(window.run) drew nothing")
            #expect(window.failed == 0, "\(window.backend) \(window.workload) run \(window.run) had failed command buffers")
            #expect(window.skipped == 0, "\(window.backend) \(window.workload) run \(window.run) skipped frames the experiment must encode")
            #expect(window.gpu.count == window.drawn, "Every drawn frame has a GPU time on this device")
            #expect(window.encode.count == window.drawn)
        }
        #expect(metal4.unsupported == 0 && raw.unsupported == 0, "The GW-09 workload is inside the experiment's supported variants")
        #endif
    }

    #if !targetEnvironment(simulator)

    /// Warm up and measure one window of the shipped conventional path.
    private static func measure(
        _ stage: OffscreenStage, workload: Case, run: Int, settings: CharacterizationTests.Settings
    ) async throws -> Window {
        try stage.renderer.setPanel(workload.panel)
        try await stage.tick(for: .seconds(settings.warmUpSeconds))
        await stage.awaitIdle()
        let metrics = RenderMetrics()
        stage.renderer.metrics = metrics
        let before = stage.scheduler.statistics
        let ticks = try await stage.tick(for: .seconds(settings.measuredSeconds))
        await stage.awaitIdle()
        stage.renderer.metrics = nil
        let delta = stage.scheduler.statistics.subtracting(before)
        let frames = metrics.samples.filter { $0.drewFrame && $0.completed }
        let counts = metrics.summary().counts
        return Window(
            backend: .conventional, workload: workload, run: run, ticks: ticks, drawn: counts.drawn,
            deferredAtBound: delta.deferredAtLimit, failed: counts.commandBuffersFailed, skipped: counts.skipped,
            gpu: frames.compactMap(\.gpuDuration), encode: frames.map(\.encodeDuration), produce: frames.map(\.produceDuration),
            allocatedBytes: frames.compactMap(\.deviceAllocatedBytes)
        )
    }

    /// Warm up and measure one window of the conventional control arm.
    private static func measure(
        _ stage: ConventionalRawStage, workload: Case, run: Int, settings: CharacterizationTests.Settings
    ) async throws -> Window {
        try stage.renderer.setPanel(workload.panel)
        try await stage.tick(for: .seconds(settings.warmUpSeconds))
        await stage.awaitIdle()
        _ = stage.drain()
        stage.resetCounts()
        let ticks = try await stage.tick(for: .seconds(settings.measuredSeconds))
        await stage.awaitIdle()
        return window(.conventionalRaw, workload: workload, run: run, ticks: ticks, timings: stage.drain(),
                      deferredAtBound: stage.deferredAtBound, skipped: stage.unsupported + stage.otherSkips)
    }

    /// Warm up and measure one window of the Metal 4 path.
    private static func measure(
        _ stage: Metal4Stage, workload: Case, run: Int, settings: CharacterizationTests.Settings
    ) async throws -> Window {
        try stage.renderer.setPanel(workload.panel)
        try await stage.tick(for: .seconds(settings.warmUpSeconds))
        await stage.awaitIdle()
        _ = stage.drain()
        stage.resetCounts()
        let ticks = try await stage.tick(for: .seconds(settings.measuredSeconds))
        await stage.awaitIdle()
        return window(.metal4, workload: workload, run: run, ticks: ticks, timings: stage.drain(),
                      deferredAtBound: stage.deferredAtBound, skipped: stage.unsupported + stage.otherSkips)
    }

    private static func window(
        _ backend: Window.Backend, workload: Case, run: Int, ticks: Int, timings: [Metal4FrameTiming],
        deferredAtBound: Int, skipped: Int
    ) -> Window {
        let completed = timings.filter(\.completed)
        return Window(
            backend: backend, workload: workload, run: run, ticks: ticks, drawn: completed.count,
            deferredAtBound: deferredAtBound, failed: timings.count - completed.count, skipped: skipped,
            gpu: completed.compactMap { $0.gpuSeconds.map { .seconds($0) } },
            encode: completed.map { .seconds($0.encodeSeconds) },
            produce: completed.map { .seconds($0.produceSeconds) },
            allocatedBytes: completed.map(\.deviceAllocatedBytes)
        )
    }

    /// What a path costs to have: `currentAllocatedSize` after creating its
    /// stage, running 30 frames, draining, and letting the driver return
    /// freed memory, minus the size before it existed; and how much of that
    /// is the stage's six big textures, so the remainder (renderer, queue,
    /// pipelines, and the Metal 4 machinery) can be compared without the
    /// conventional pool's lazy allocation of its third source texture.
    struct Footprint {
        let name: String
        let bytes: Int
        let textureBytes: Int
        let returnedBytes: Int
        var machinery: String = ""
    }

    private static let settleDelay = Duration.milliseconds(200)

    /// The bytes of one render target at the workload size, from a probe.
    private static func targetBytes(device: any MTLDevice) throws -> Int {
        try Metal4Textures(device: device, size: Workload.portrait, count: 1).targets[0].allocatedSize
    }

    private static func footprintOfConventional() async throws -> Footprint {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let targets = try targetBytes(device: device)
        try await Task.sleep(for: settleDelay)
        let baseline = device.currentAllocatedSize
        var bytes = 0
        var textures = 0
        do {
            let stage = try OffscreenStage()
            try await stage.tick(count: 30)
            await stage.awaitIdle()
            try await Task.sleep(for: settleDelay)
            bytes = device.currentAllocatedSize - baseline
            textures = stage.pool.statistics.liveBytes + Workload.renderTargets * targets
        }
        try await Task.sleep(for: settleDelay)
        return Footprint(name: "conventional (shipped)", bytes: bytes, textureBytes: textures, returnedBytes: device.currentAllocatedSize - baseline)
    }

    private static func footprintOfRaw() async throws -> Footprint {
        let device = try #require(MTLCreateSystemDefaultDevice())
        try await Task.sleep(for: settleDelay)
        let baseline = device.currentAllocatedSize
        var bytes = 0
        var textures = 0
        do {
            let stage = try ConventionalRawStage()
            for _ in 0..<30 {
                stage.tick()
                try await Task.sleep(for: Workload.tickInterval)
            }
            await stage.awaitIdle()
            try await Task.sleep(for: settleDelay)
            bytes = device.currentAllocatedSize - baseline
            textures = stage.textures.allocations.reduce(0) { $0 + (($1 as? any MTLTexture).map { $0.parent == nil && $0.buffer == nil ? $0.allocatedSize : 0 } ?? 0) }
        }
        try await Task.sleep(for: settleDelay)
        return Footprint(name: "conventional control", bytes: bytes, textureBytes: textures, returnedBytes: device.currentAllocatedSize - baseline)
    }

    private static func footprintOfMetal4() async throws -> Footprint {
        let device = try #require(MTLCreateSystemDefaultDevice())
        try await Task.sleep(for: settleDelay)
        let baseline = device.currentAllocatedSize
        var bytes = 0
        var textures = 0
        var machinery = ""
        do {
            let stage = try Metal4Stage()
            for _ in 0..<30 {
                stage.tick()
                try await Task.sleep(for: Workload.tickInterval)
            }
            await stage.awaitIdle()
            try await Task.sleep(for: settleDelay)
            bytes = device.currentAllocatedSize - baseline
            textures = stage.textures.allocations.reduce(0) { $0 + (($1 as? any MTLTexture).map { $0.parent == nil && $0.buffer == nil ? $0.allocatedSize : 0 } ?? 0) }
            machinery = "command allocators \(stage.metal4.allocatorBytes) B, uniform ring \(stage.metal4.uniformRingBytes) B, residency set reports \(stage.metal4.residencySetBytes) B (it tracks the textures; not extra memory)"
        }
        try await Task.sleep(for: settleDelay)
        return Footprint(name: "metal4 (experiment)", bytes: bytes, textureBytes: textures, returnedBytes: device.currentAllocatedSize - baseline, machinery: machinery)
    }

    // MARK: Report

    private static func report(
        settings: CharacterizationTests.Settings, device: any MTLDevice,
        conventional: OffscreenStage, metal4: Metal4Stage, windows: [Window],
        compile: [Metal4PipelineCompileSample], renderersBeforeCompile: Int, footprints: [Footprint],
        thermalStates: (start: ProcessInfo.ThermalState, end: ProcessInfo.ThermalState)
    ) -> String {
        var lines: [String] = []
        let capabilities = RenderCapabilities(device: device)
        #if DEBUG
        let configuration = "Debug (DEBUG defined)"
        #else
        let configuration = "Release (DEBUG not defined)"
        #endif
        lines.append("GlassWeave GW-11: Metal 4 against conventional submission, workload version \(Workload.version)")
        lines.append("Machine GPU: \(capabilities.deviceName); highest Apple family apple\(capabilities.highestAppleFamily.map(String.init) ?? "none"), Metal 3 \(capabilities.supportsMetal3), Metal 4 \(capabilities.supportsMetal4); backend selected for the experiment: \(capabilities.submissionBackend(preferringMetal4: true))")
        lines.append("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Build: \(configuration); conventional queue class \(conventional.queueClassName); Metal 4 queue class \(String(describing: type(of: metal4.metal4.queue)))")
        lines.append("Conditions: thermal state \(Report.describe(thermalStates.start)) at start, \(Report.describe(thermalStates.end)) at end; Low Power Mode \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")")
        lines.append("Settings: \(settings.runs) run(s), \(settings.measuredSeconds) s measured after \(settings.warmUpSeconds) s warm-up per window")
        lines.append("Workload: target \(Workload.portrait.width)×\(Workload.portrait.height) px at scale \(Workload.displayScale); the GW-09 producer pass into a ring of \(Workload.poolCapacity) textures, then the background and one panel in one render pass; 60 Hz requests; in-flight bound \(FrameStatistics.boundForCharacterization); \(Workload.renderTargets) render targets; frame-ID strip off")
        lines.append("Arms: conventional = the shipped GlassRenderer.drawProducing (leases, validation); conventionalRaw = the control, the same plan through conventional Metal without the lease machinery; metal4 = Metal4Renderer.submit (argument tables, residency set, MTL4CommandQueue). All three use the same shader library, the same pipeline states and the same records. Cases: panel (base variant) and lens (optics variant: circular profile, thickness 28, dispersion 0.35).")
        lines.append("Interleaving: per run and per case the order of the three arms rotates; each window is one arm alone (the GPU never runs two arms at once).")
        lines.append("")

        lines.append("Pipeline compilation (seconds; the same functions, constants and attachment through each API). \(renderersBeforeCompile) GlassWeave renderer(s) had been created in this process before this measurement: 0 means these are the first creations in the process (the on-disk Metal shader cache can still be warm); more means the glass pipelines were already built by the legacy API, so the first Metal 4 compile is not comparable with it. Later creations of an identical pipeline can hit a shader cache.")
        for sample in compile {
            lines.append(String(format: "  %@ via %@, creation #%d of this pipeline: %.4f s", sample.label, sample.api.rawValue, sample.sequenceIndex, sample.seconds))
        }
        lines.append("")

        lines.append("Creation footprint (device.currentAllocatedSize with a stage alive after 30 frames, drained, minus the size before it existed; the textures are the six big resources, the remainder is renderer, queue, pipelines and API machinery):")
        for footprint in footprints {
            lines.append("  \(footprint.name): \(footprint.bytes) B (\(Report.mebibytes(footprint.bytes))), textures \(footprint.textureBytes) B, remainder \(footprint.bytes - footprint.textureBytes) B; \(footprint.returnedBytes) B still allocated after the stage was dropped\(footprint.machinery.isEmpty ? "" : "; " + footprint.machinery)")
        }
        if let shipped = footprints.first(where: { $0.name.hasPrefix("conventional (") }),
           let control = footprints.first(where: { $0.name.hasPrefix("conventional control") }),
           let experiment = footprints.first(where: { $0.name.hasPrefix("metal4") }) {
            lines.append("  remainder difference: metal4 − conventional control \(experiment.bytes - experiment.textureBytes - (control.bytes - control.textureBytes)) B; metal4 − conventional shipped \(experiment.bytes - experiment.textureBytes - (shipped.bytes - shipped.textureBytes)) B")
        }
        lines.append("")

        lines.append("Per window (ms; nearest-rank p50/p95/p99/max):")
        for window in windows {
            lines.append("  run \(window.run) \(window.workload.rawValue) \(window.backend.rawValue): \(window.ticks) ticks, \(window.drawn) drawn, \(window.deferredAtBound) deferred at bound, \(window.failed) failed, \(window.skipped) skipped")
            lines.append("    GPU     \(Report.describe(RenderMetrics.Distribution(window.gpu)))")
            lines.append("    encode  \(Report.describe(RenderMetrics.Distribution(window.encode)))")
            lines.append("    produce \(Report.describe(RenderMetrics.Distribution(window.produce)))")
            lines.append("    allocated at commit: first \(window.allocatedBytes.first.map(String.init) ?? "n/a") B, last \(window.allocatedBytes.last.map(String.init) ?? "n/a") B, peak \(window.allocatedBytes.max().map(String.init) ?? "n/a") B")
        }
        lines.append("")

        lines.append("Pooled per case and arm:")
        for workload in Case.allCases {
            var pooled: [Window.Backend: (gpu: RenderMetrics.Distribution?, encode: RenderMetrics.Distribution?)] = [:]
            for backend in Window.Backend.allCases {
                let mine = windows.filter { $0.workload == workload && $0.backend == backend }
                let gpu = RenderMetrics.Distribution(mine.flatMap(\.gpu))
                let encode = RenderMetrics.Distribution(mine.flatMap(\.encode))
                pooled[backend] = (gpu, encode)
                lines.append("  \(workload.rawValue) \(backend.rawValue): \(mine.reduce(0) { $0 + $1.drawn }) frames")
                lines.append("    GPU     \(Report.describe(gpu))")
                lines.append("    encode  \(Report.describe(encode))")
                lines.append("    produce \(Report.describe(RenderMetrics.Distribution(mine.flatMap(\.produce))))")
            }
            for (name, subject, baseline) in [
                ("metal4 − conventionalRaw (API only, the decision comparison)", Window.Backend.metal4, Window.Backend.conventionalRaw),
                ("conventional − conventionalRaw (what the lease machinery costs)", .conventional, .conventionalRaw),
                ("metal4 − conventional (experiment against the shipped path)", .metal4, .conventional),
            ] {
                guard let s = pooled[subject], let b = pooled[baseline] else { continue }
                lines.append("  \(workload.rawValue) \(name): GPU p50 \(Report.difference(s.gpu?.p50, b.gpu?.p50)), GPU p95 \(Report.difference(s.gpu?.p95, b.gpu?.p95)), encode p50 \(Report.difference(s.encode?.p50, b.encode?.p50)), encode p95 \(Report.difference(s.encode?.p95, b.encode?.p95))")
                var ratios = "    ratios subject / baseline:"
                if let sp = s.gpu?.p50, let bp = b.gpu?.p50, bp > .zero { ratios += String(format: " GPU p50 %.3f", Report.milliseconds(sp) / Report.milliseconds(bp)) }
                if let sp = s.gpu?.p95, let bp = b.gpu?.p95, bp > .zero { ratios += String(format: ", GPU p95 %.3f", Report.milliseconds(sp) / Report.milliseconds(bp)) }
                if let sp = s.encode?.p50, let bp = b.encode?.p50, bp > .zero { ratios += String(format: ", encode p50 %.3f", Report.milliseconds(sp) / Report.milliseconds(bp)) }
                if let sp = s.encode?.p95, let bp = b.encode?.p95, bp > .zero { ratios += String(format: ", encode p95 %.3f", Report.milliseconds(sp) / Report.milliseconds(bp)) }
                lines.append(ratios)
            }
        }
        lines.append("")

        lines.append("Steady state (per arm, cases pooled: GPU of the first third of each window's frames against the last third; device allocation across the windows):")
        for backend in Window.Backend.allCases {
            let mine = windows.filter { $0.backend == backend }
            var first: [Duration] = []
            var last: [Duration] = []
            for window in mine where window.gpu.count >= 6 {
                let third = window.gpu.count / 3
                first += window.gpu.prefix(third)
                last += window.gpu.suffix(third)
            }
            let growth = (mine.last?.allocatedBytes.last ?? 0) - (mine.first?.allocatedBytes.first ?? 0)
            lines.append("  \(backend.rawValue): GPU first third \(Report.describe(RenderMetrics.Distribution(first))), last third \(Report.describe(RenderMetrics.Distribution(last))); failed command buffers \(mine.reduce(0) { $0 + $1.failed }); allocated bytes, first commit to last commit: \(growth >= 0 ? "+" : "")\(growth) B (device-wide, so it includes the other arms' resources, which exist throughout)")
        }
        lines.append("  Metal 4 command allocators after the run: \(metal4.metal4.allocatorBytes) B")
        lines.append("")
        lines.append("Decision rule and status: see docs/decisions/metal-backend.md. This report is a smoke run unless the settings above say otherwise.")
        return lines.joined(separator: "\n")
    }
    #endif
}
