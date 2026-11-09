import CoreGraphics
import Foundation
import GlassWeave
import Metal
import Testing

/// GW-09's fixed first-milestone workload, rendered offscreen on the GPU the
/// tests run on and measured with `RenderMetrics`.
///
/// This characterizes the machine running the tests (in development, an
/// Apple-silicon Mac). It is never evidence for an iPhone or iPad: the GPU,
/// clocks, memory, thermals, display, and compositor all differ, and the
/// native reference glass (composited by the system) is not part of an
/// offscreen render. The modes compared are the laboratory's mode 1 (the
/// owned moving background alone) and the GlassWeave share of mode 3 (the
/// same background plus one custom panel).
///
/// The workload mirrors the laboratory's benchmark scenario: a 402 × 874
/// point surface at display scale 3 (1206 × 2622 pixels, the iPhone 18 Pro
/// simulator's screen), the laboratory's procedural background shader (a
/// copy of `ProceduralBackground.metal`) produced inside each draw's
/// command buffer into a three-texture `FrameTexturePool`, the frame-ID strip
/// off, one 320 × 180 point panel with the laboratory's light parameters,
/// one request per 60 Hz tick, the surface's in-flight bound of two, and
/// three render targets cycling like a layer's drawables.
///
/// Settings come from the environment, so one test serves two purposes:
/// - Unset (the GlassWeave scheme and CI): one short run per mode under the
///   scheme's Metal API Validation, checking the measurement path and its
///   bounds. Its timings are not characterization data.
/// - The GlassWeaveCharacterization scheme: Release, no validation layer,
///   longer interleaved runs whose summary is printed and attached.
@Suite(.serialized)
struct CharacterizationTests {
    struct Settings: CustomStringConvertible {
        var runs = 1
        var measuredSeconds = 1.0
        var warmUpSeconds = 0.5
        var lifecycleCycles = 10

        static var current: Settings {
            let environment = ProcessInfo.processInfo.environment
            var settings = Settings()
            if let value = environment["GLASSWEAVE_CHARACTERIZATION_RUNS"].flatMap(Int.init) { settings.runs = value }
            if let value = environment["GLASSWEAVE_CHARACTERIZATION_SECONDS"].flatMap(Double.init) { settings.measuredSeconds = value }
            if let value = environment["GLASSWEAVE_CHARACTERIZATION_WARMUP_SECONDS"].flatMap(Double.init) { settings.warmUpSeconds = value }
            if let value = environment["GLASSWEAVE_CHARACTERIZATION_LIFECYCLE_CYCLES"].flatMap(Int.init) { settings.lifecycleCycles = value }
            return settings
        }

        var description: String {
            "\(runs) run(s) per mode, \(measuredSeconds) s measured after \(warmUpSeconds) s warm-up, \(lifecycleCycles) lifecycle cycles"
        }
    }

    /// The fixed workload. Version 1 matches the laboratory's
    /// `BenchmarkScenario.version`.
    enum Workload {
        static let version = 1
        static let displayScale = 3.0
        static let portrait = (width: 1206, height: 2622)
        static let landscape = (width: 2622, height: 1206)
        /// 320 × 180 points, centered on the 402 × 874 point surface.
        static let panel = GlassPanel(
            frame: CGRect(x: 41, y: 347, width: 320, height: 180),
            parameters: GlassParameters(
                cornerRadius: 30, bezelWidth: 22, refraction: 0.85, edgeHighlight: 0.6,
                tint: GlassTint(red: 0.97, green: 0.98, blue: 1.0, strength: 0.45)
            )
        )
        static let ticksPerSecond = 60
        static let tickInterval = Duration.nanoseconds(1_000_000_000 / Int64(ticksPerSecond))
        static let renderTargets = 3
        static let poolCapacity = 3
    }

    enum Mode: String, CaseIterable {
        /// Laboratory mode 1: the owned moving background, no custom panel.
        case background
        /// The GlassWeave share of laboratory mode 3: the same background
        /// and one custom panel.
        case panel
    }

    /// One measured run of one mode.
    struct RunResult {
        let mode: Mode
        let run: Int
        let ticks: Int
        let summary: RenderMetrics.Summary
        let statistics: FrameStatistics
        let exhaustedCheckouts: Int
        let poolBytes: Int
        /// The drawn, completed frames, for distributions pooled over runs.
        let frames: [RenderMetrics.Sample]
    }

    @Test(.timeLimit(.minutes(30)))
    func `The fixed workload's cost, idle behavior, and retained memory`() async throws {
        let settings = Settings.current
        let thermalStateAtStart = ProcessInfo.processInfo.thermalState
        let stage = try OffscreenStage()
        var results: [RunResult] = []

        // Interleave the modes and alternate which goes first, so neither
        // always runs warmer or later.
        for run in 1...settings.runs {
            let order: [Mode] = run.isMultiple(of: 2) ? [.panel, .background] : [.background, .panel]
            for mode in order {
                try stage.renderer.setPanel(mode == .panel ? Workload.panel : nil)
                try await stage.tick(for: .seconds(settings.warmUpSeconds))
                await stage.awaitIdle()
                let metrics = RenderMetrics()
                stage.renderer.metrics = metrics
                let before = stage.scheduler.statistics
                let exhaustedBefore = stage.pool.statistics.exhaustedCheckouts
                let ticks = try await stage.tick(for: .seconds(settings.measuredSeconds))
                await stage.awaitIdle()
                stage.renderer.metrics = nil
                let after = stage.scheduler.statistics
                results.append(RunResult(
                    mode: mode, run: run, ticks: ticks, summary: metrics.summary(),
                    statistics: after.subtracting(before),
                    exhaustedCheckouts: stage.pool.statistics.exhaustedCheckouts - exhaustedBefore,
                    poolBytes: stage.pool.statistics.liveBytes,
                    frames: metrics.samples.filter { $0.drewFrame && $0.completed }
                ))
            }
        }

        // Idle: a frozen source and settled panel request nothing, so
        // nothing is submitted.
        let idleSeconds = min(settings.measuredSeconds, 5)
        let submittedBeforeIdle = stage.scheduler.statistics.submitted
        try await Task.sleep(for: .seconds(idleSeconds))
        let idleSubmissions = stage.scheduler.statistics.submitted - submittedBeforeIdle

        // Lifecycle: settle, then hide (trimming the pool), request while
        // hidden, show, and rotate the target, `lifecycleCycles` times, and
        // settle again at the original size. Allocations are compared after
        // pending GPU work has retired.
        try await stage.tick(for: .seconds(0.5))
        await stage.awaitIdle()
        let settledBefore = stage.device.currentAllocatedSize
        let poolBefore = stage.pool.statistics
        for cycle in 0..<settings.lifecycleCycles {
            stage.setVisible(false)
            stage.pool.trim()
            try await stage.tick(count: 2)
            stage.setVisible(true)
            stage.resize(to: cycle.isMultiple(of: 2) ? Workload.landscape : Workload.portrait)
            try await stage.tick(count: 4)
        }
        stage.resize(to: Workload.portrait)
        try await stage.tick(for: .seconds(0.5))
        await stage.awaitIdle()
        // Let the driver return memory of resources freed by completed work.
        try await Task.sleep(for: .milliseconds(200))
        let settledAfter = stage.device.currentAllocatedSize
        let poolAfter = stage.pool.statistics

        let report = Report(
            settings: settings, stage: stage, results: results,
            thermalStates: (thermalStateAtStart, ProcessInfo.processInfo.thermalState),
            idleSeconds: idleSeconds, idleSubmissions: idleSubmissions,
            lifecycle: (settledBefore, settledAfter, poolBefore, poolAfter)
        )
        print(report.text)
        Attachment.record(report.text, named: "glassweave-characterization.txt")

        // Checks that hold on any GPU: the measurement path and the bounds.
        for result in results {
            let counts = result.summary.counts
            #expect(counts.drawn > 0, "\(result.mode) run \(result.run) drew nothing")
            #expect(counts.commandBuffersFailed == 0)
            #expect(counts.commandBuffersCompleted == counts.commandBuffersCommitted)
            #expect(result.summary.encode?.count == counts.drawn, "Every drawn frame has a sample")
            #expect(result.statistics.peakFramesInFlight <= FrameStatistics.boundForCharacterization)
            if let gpu = result.summary.gpu {
                #expect(gpu.p50 <= gpu.p95 && gpu.p95 <= gpu.p99 && gpu.p99 <= gpu.maximum)
            }
            #if !targetEnvironment(simulator)
            #expect(result.summary.samplesWithoutGPUTime == 0, "This GPU reports command buffer times")
            #endif
        }
        #expect(idleSubmissions == 0)
        #expect(poolAfter.liveTextures <= Workload.poolCapacity)
        #if targetEnvironment(simulator)
        // The iOS Simulator reports no allocation sizes, so retained memory
        // is not measured there.
        #expect(settledBefore == 0 && settledAfter == 0)
        #else
        #expect(settledBefore > 0)
        #expect(settledAfter <= settledBefore, "Allocations grew over \(settings.lifecycleCycles) lifecycle cycles: \(settledBefore) → \(settledAfter) bytes")
        #endif
    }
}

extension FrameStatistics {
    /// The in-flight bound the offscreen stage uses: `GlassSurfaceView`'s.
    static let boundForCharacterization = FrameScheduler.defaultMaxFramesInFlight

    /// The counts accumulated between two snapshots.
    func subtracting(_ earlier: FrameStatistics) -> FrameStatistics {
        var delta = FrameStatistics()
        delta.requested = requested - earlier.requested
        delta.coalesced = coalesced - earlier.coalesced
        delta.submitted = submitted - earlier.submitted
        delta.completed = completed - earlier.completed
        delta.skipped = skipped - earlier.skipped
        delta.deferredWhileHidden = deferredWhileHidden - earlier.deferredWhileHidden
        delta.deferredAtLimit = deferredAtLimit - earlier.deferredAtLimit
        delta.framesInFlight = framesInFlight
        delta.peakFramesInFlight = peakFramesInFlight
        return delta
    }
}
