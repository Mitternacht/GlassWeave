import Foundation
import GlassWeave
import Metal

/// The plain-text record of one characterization run: environment, every
/// run's distributions, distributions pooled per mode, the comparative GPU
/// statistic, the idle check, and lifecycle allocations.
struct Report {
    typealias Workload = CharacterizationTests.Workload
    typealias Mode = CharacterizationTests.Mode

    /// The idle period: display passes with nothing requested.
    struct Idle {
        let seconds: Double
        let passes: Int
        let submissions: Int
        let productions: Int
    }

    let text: String

    init(
        settings: CharacterizationTests.Settings,
        stage: OffscreenStage,
        results: [CharacterizationTests.RunResult],
        thermalStates: (start: ProcessInfo.ThermalState, end: ProcessInfo.ThermalState),
        idle: Idle,
        lifecycle: (before: Int, after: Int, poolBefore: FrameTexturePool.Statistics, poolAfter: FrameTexturePool.Statistics)
    ) {
        var lines: [String] = []
        let capabilities = RenderCapabilities(device: stage.device)
        #if DEBUG
        let configuration = "Debug (DEBUG defined)"
        #else
        let configuration = "Release (DEBUG not defined)"
        #endif
        #if targetEnvironment(simulator)
        let environment = "iOS Simulator"
        #else
        let environment = "native"
        #endif
        lines.append("GlassWeave characterization, workload version \(Workload.version)")
        lines.append("Machine GPU: \(capabilities.deviceName), \(environment); highest Apple family apple\(capabilities.highestAppleFamily.map(String.init) ?? "none"), Metal 3 \(capabilities.supportsMetal3), Metal 4 \(capabilities.supportsMetal4)")
        lines.append("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Build: \(configuration); command queue class \(stage.queueClassName)")
        lines.append("Conditions: thermal state \(Self.describe(thermalStates.start)) at start, \(Self.describe(thermalStates.end)) at end; Low Power Mode \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")")
        lines.append("Settings: \(settings)")
        lines.append("Workload: target \(Workload.portrait.width)×\(Workload.portrait.height) px at scale \(Workload.displayScale); panel 320×180 pt = \(Int(320 * Workload.displayScale))×\(Int(180 * Workload.displayScale)) px; \(Workload.ticksPerSecond) Hz requests; in-flight bound \(FrameStatistics.boundForCharacterization); pool \(Workload.poolCapacity); frame-ID strip off")
        let glow = Workload.glowPanel.parameters.glow
        let interior = Workload.interiorPanel(.energy).parameters.interior
        lines.append("Interior modes (GW-19): the glow mode plus an energy, rays, or embers interior, \(interior.colors.count) colors, intensity \(interior.intensity), speed \(interior.speed), center fade \(interior.centerFade), moving with the effect time")
        lines.append("Glow mode (GW-18): the panel plus \(glow.colors.count) colors, rim \(glow.rimWidth) + \(glow.rimSoftness) pt, inner glow \(glow.innerGlowRadius) pt × \(glow.innerGlowIntensity), halo \(glow.haloRadius) pt × \(glow.haloIntensity) (quad \(Int((320 + 2 * glow.haloRadius) * Workload.displayScale) + 2)×\(Int((180 + 2 * glow.haloRadius) * Workload.displayScale) + 2) px), pulse \(glow.pulsePeriod) s × \(glow.pulseDepth), effect time advancing 1/\(Workload.ticksPerSecond) s per tick")
        lines.append("")
        lines.append("Per run (ms; nearest-rank percentiles p50/p95/p99/max):")
        for result in results {
            let counts = result.summary.counts
            lines.append("  run \(result.run) \(result.mode.rawValue): \(result.ticks) ticks, \(counts.drawn) drawn, \(counts.declinedProductions) declined productions, \(result.exhaustedCheckouts) pool-exhausted, \(result.statistics.coalesced) coalesced, \(result.statistics.deferredAtLimit) deferred at bound, \(counts.skipped) skipped, \(counts.commandBuffersFailed) failed")
            lines.append("    GPU     \(Self.describe(result.summary.gpu)) (\(result.summary.samplesWithoutGPUTime) frames without GPU time)")
            lines.append("    encode  \(Self.describe(result.summary.encode))")
            lines.append("    produce \(Self.describe(result.summary.produce))")
            lines.append("    acquire \(Self.describe(result.summary.targetAcquisition))")
            lines.append("    Metal allocated: peak \(Self.mebibytes(result.summary.peakDeviceAllocatedBytes)), pool textures \(Self.mebibytes(result.poolBytes))")
        }
        lines.append("")
        lines.append("Pooled per mode:")
        var pooledGPU: [Mode: RenderMetrics.Distribution] = [:]
        for mode in Mode.allCases {
            let frames = results.filter { $0.mode == mode }.flatMap(\.frames)
            let gpu = RenderMetrics.Distribution(frames.compactMap(\.gpuDuration))
            pooledGPU[mode] = gpu
            lines.append("  \(mode.rawValue): \(frames.count) frames")
            lines.append("    GPU     \(Self.describe(gpu))")
            lines.append("    encode  \(Self.describe(RenderMetrics.Distribution(frames.map(\.encodeDuration))))")
            lines.append("    produce \(Self.describe(RenderMetrics.Distribution(frames.map(\.produceDuration))))")
            lines.append("    acquire \(Self.describe(RenderMetrics.Distribution(frames.map(\.targetAcquisitionDuration))))")
        }
        lines.append("")
        for (mode, baseline) in [
            (Mode.panel, Mode.background), (.glow, .panel), (.glow, .background),
            (.energy, .glow), (.rays, .glow), (.embers, .glow),
        ] {
            lines.append("Comparative GPU statistic, p95(\(mode.rawValue)) − p95(\(baseline.rawValue)):")
            for run in Set(results.map(\.run)).sorted() {
                let base = results.first { $0.run == run && $0.mode == baseline }?.summary.gpu
                let measured = results.first { $0.run == run && $0.mode == mode }?.summary.gpu
                lines.append("  run \(run): \(Self.difference(measured?.p95, base?.p95))")
            }
            lines.append("  pooled: \(Self.difference(pooledGPU[mode]?.p95, pooledGPU[baseline]?.p95))")
        }
        lines.append("")
        lines.append("Idle: \(idle.passes) display passes in \(idle.seconds) s with nothing requested: \(idle.submissions) submissions, \(idle.productions) frames produced")
        lines.append("Lifecycle: \(settings.lifecycleCycles) cycles of hide (trim) / 2 hidden ticks / show / rotate / 4 ticks")
        if lifecycle.before == 0, lifecycle.after == 0 {
            lines.append("  settled currentAllocatedSize: not reported by this device (0 B)")
        } else {
            lines.append("  settled currentAllocatedSize before \(lifecycle.before) B (\(Self.mebibytes(lifecycle.before))), after \(lifecycle.after) B (\(Self.mebibytes(lifecycle.after))), change \(lifecycle.after - lifecycle.before) B")
        }
        lines.append("  pool before: \(lifecycle.poolBefore.liveTextures) textures, \(Self.mebibytes(lifecycle.poolBefore.liveBytes)), \(lifecycle.poolBefore.allocations) allocations; after: \(lifecycle.poolAfter.liveTextures) textures, \(Self.mebibytes(lifecycle.poolAfter.liveBytes)), \(lifecycle.poolAfter.allocations) allocations, \(lifecycle.poolAfter.discarded) discarded")
        text = lines.joined(separator: "\n")
    }

    static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    static func describe(_ distribution: RenderMetrics.Distribution?) -> String {
        guard let distribution else { return "no samples" }
        let values = [distribution.p50, distribution.p95, distribution.p99, distribution.maximum]
            .map { String(format: "%.3f", milliseconds($0)) }
        return values.joined(separator: " / ") + " (n \(distribution.count))"
    }

    static func difference(_ a: Duration?, _ b: Duration?) -> String {
        guard let a, let b else { return "not measured (no GPU times)" }
        return String(format: "%+.3f ms", milliseconds(a - b))
    }

    static func mebibytes(_ bytes: Int?) -> String {
        guard let bytes else { return "n/a" }
        return String(format: "%.1f MiB", Double(bytes) / 1_048_576)
    }
}
