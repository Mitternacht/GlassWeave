import Metal
import Synchronization

/// The measured cost of the frames one ``GlassRenderer`` submits.
///
/// Assign a recorder to ``GlassRenderer/metrics`` to measure that renderer;
/// with none assigned, the renderer reads no clock and records nothing.
///
/// For every command buffer the renderer commits, a ``Sample`` records:
/// - **CPU time** on the thread that called the draw, from the start of the
///   draw call until just before the command buffer is committed, split into
///   the app's producer (the `produce` closure of
///   ``GlassRenderer/drawProducing(targetPixelSize:displayScale:produce:acquireTarget:)``),
///   target acquisition (the host's `acquireTarget`, where an `MTKView` host
///   may wait for a drawable), and GlassWeave's own preparation and encoding
///   (the rest).
/// - **GPU time**: the command buffer's `gpuStartTime` and `gpuEndTime`, read
///   in its completed handler. A device that reports neither (both zero)
///   gives `nil`, never a zero duration.
/// - **Allocated bytes**: the device's `currentAllocatedSize` at commit. This
///   is everything the process has allocated on that device (the app's
///   resources and drawables as well as GlassWeave's), not GlassWeave's share.
///   A device that reports zero (the iOS Simulator does) gives `nil`.
///
/// ``counts`` keeps totals of draws, skips, rejected and declined
/// productions, and command buffers. ``samples`` keeps only the most recent
/// ``capacity`` samples, so a long run uses bounded memory; ``summary()``
/// reduces them to percentile ``Distribution``s.
///
/// A recorder is thread-safe: samples arrive from Metal completion threads.
/// ``reset()`` starts a new measurement window; command buffers committed
/// before it are neither sampled nor counted after it.
public final class RenderMetrics: Sendable {
    /// The measured cost of one committed command buffer.
    public struct Sample: Hashable, Sendable {
        /// The source frame the command buffer drew or carried the writes of.
        public let frameID: UInt64
        /// Whether the command buffer drew the background (and panel) into a
        /// target. `false` when it carried only a produced frame's writes,
        /// because no drawable was available or the frame was rejected.
        public let drewFrame: Bool
        /// GlassWeave's CPU time in the draw call: preparation and encoding,
        /// excluding ``produceDuration`` and ``targetAcquisitionDuration``.
        public let encodeDuration: Duration
        /// CPU time in the app's frame producer.
        public let produceDuration: Duration
        /// CPU time in the host's target acquisition (for an `MTKView`,
        /// `currentRenderPassDescriptor` and `currentDrawable`).
        public let targetAcquisitionDuration: Duration
        /// When the GPU started the command buffer, in host time seconds
        /// (`MTLCommandBuffer.gpuStartTime`), or `nil` if not reported.
        public let gpuStartTime: Double?
        /// When the GPU finished the command buffer, in host time seconds
        /// (`MTLCommandBuffer.gpuEndTime`), or `nil` if not reported.
        public let gpuEndTime: Double?
        /// Whether the command buffer completed without an error.
        public let completed: Bool
        /// `MTLDevice.currentAllocatedSize` when the command buffer was
        /// committed, or `nil` if the device reported zero.
        public let deviceAllocatedBytes: Int?

        init(
            frameID: UInt64, drewFrame: Bool,
            encodeDuration: Duration, produceDuration: Duration, targetAcquisitionDuration: Duration,
            gpuStartTime: Double?, gpuEndTime: Double?,
            completed: Bool, deviceAllocatedBytes: Int?
        ) {
            self.frameID = frameID
            self.drewFrame = drewFrame
            self.encodeDuration = encodeDuration
            self.produceDuration = produceDuration
            self.targetAcquisitionDuration = targetAcquisitionDuration
            self.gpuStartTime = gpuStartTime
            self.gpuEndTime = gpuEndTime
            self.completed = completed
            self.deviceAllocatedBytes = deviceAllocatedBytes
        }

        /// The GPU execution time, or `nil` if the device reported none.
        public var gpuDuration: Duration? {
            guard let gpuStartTime, let gpuEndTime else { return nil }
            return .seconds(gpuEndTime - gpuStartTime)
        }
    }

    /// Totals since the recorder was created or last reset.
    public struct Counts: Hashable, Sendable {
        /// Draw calls the renderer received (`draw` and `drawProducing`).
        public var draws = 0
        /// Draws that drew into a target and committed it.
        public var drawn = 0
        /// Draws that ended in a defined skip (``BackgroundRenderSkipReason``).
        /// A skip after a frame was produced still commits its writes.
        public var skipped = 0
        /// `drawProducing` calls whose produced frame the renderer rejected.
        public var rejected = 0
        /// `drawProducing` calls whose producer returned no frame, so the
        /// current frame was drawn again: a dropped production.
        public var declinedProductions = 0
        /// Command buffers committed.
        public var commandBuffersCommitted = 0
        /// Committed command buffers that completed without an error.
        public var commandBuffersCompleted = 0
        /// Committed command buffers that finished with an error.
        public var commandBuffersFailed = 0

        public init() {}
    }

    /// Percentiles of a set of durations.
    ///
    /// Percentiles use the nearest-rank definition: the *p*th percentile of
    /// *n* sorted values is the value at rank ⌈*p* · *n* / 100⌉ (ranks start
    /// at 1). Every reported value is therefore an observed sample.
    public struct Distribution: Hashable, Sendable {
        public let count: Int
        public let p50: Duration
        public let p95: Duration
        public let p99: Duration
        public let maximum: Duration

        /// The distribution of `values`, or `nil` when there are none.
        public init?(_ values: [Duration]) {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            count = sorted.count
            p50 = Self.percentile(50, ofSorted: sorted)
            p95 = Self.percentile(95, ofSorted: sorted)
            p99 = Self.percentile(99, ofSorted: sorted)
            maximum = sorted[sorted.count - 1]
        }

        /// The nearest-rank `percent`th percentile of ascending `sorted`
        /// values. The rank is computed in integers.
        static func percentile(_ percent: Int, ofSorted sorted: [Duration]) -> Duration {
            precondition((1...100).contains(percent) && !sorted.isEmpty)
            let rank = (percent * sorted.count + 99) / 100
            return sorted[rank - 1]
        }
    }

    /// The window's samples reduced to distributions.
    ///
    /// Distributions use only samples that drew a frame and completed, so a
    /// production-only command buffer (no drawable) does not dilute the
    /// per-frame cost.
    public struct Summary: Hashable, Sendable {
        public let counts: Counts
        /// GlassWeave's CPU preparation and encoding per drawn frame.
        public let encode: Distribution?
        /// The app's producer per drawn frame.
        public let produce: Distribution?
        /// Target acquisition per drawn frame.
        public let targetAcquisition: Distribution?
        /// GPU execution per drawn frame, from samples with GPU timestamps.
        public let gpu: Distribution?
        /// Drawn, completed samples without GPU timestamps.
        public let samplesWithoutGPUTime: Int
        /// The highest and the most recent `currentAllocatedSize` sampled, or
        /// `nil` if the device reported none.
        public let peakDeviceAllocatedBytes: Int?
        public let latestDeviceAllocatedBytes: Int?
    }

    /// The most samples kept. Older samples leave the window; counts keep
    /// their totals.
    public let capacity: Int

    private struct State {
        var generation = 0
        var counts = Counts()
        /// A ring of at most `capacity` samples; `next` is the oldest once
        /// the ring is full.
        var ring: [Sample] = []
        var next = 0
    }

    private let state: Mutex<State>

    /// - Parameter capacity: The most samples kept, at least one. The
    ///   default holds five minutes of frames at 60 Hz.
    public init(capacity: Int = 18_000) {
        precondition(capacity > 0, "A metrics recorder keeps at least one sample")
        self.capacity = capacity
        state = Mutex(State())
    }

    /// The samples in the window, oldest first.
    public var samples: [Sample] {
        state.withLock { Self.chronological($0) }
    }

    private static func chronological(_ state: State) -> [Sample] {
        Array(state.ring[state.next...] + state.ring[..<state.next])
    }

    public var counts: Counts {
        state.withLock { $0.counts }
    }

    /// Starts a new window: clears samples and counts. Command buffers
    /// committed before the reset are ignored when they complete.
    public func reset() {
        state.withLock { state in
            state = State(generation: state.generation + 1)
        }
    }

    /// Reduces the window's samples to distributions.
    public func summary() -> Summary {
        let (counts, samples) = state.withLock { ($0.counts, Self.chronological($0)) }
        let frames = samples.filter { $0.drewFrame && $0.completed }
        let gpu = frames.compactMap(\.gpuDuration)
        return Summary(
            counts: counts,
            encode: Distribution(frames.map(\.encodeDuration)),
            produce: Distribution(frames.map(\.produceDuration)),
            targetAcquisition: Distribution(frames.map(\.targetAcquisitionDuration)),
            gpu: Distribution(gpu),
            samplesWithoutGPUTime: frames.count - gpu.count,
            peakDeviceAllocatedBytes: samples.compactMap(\.deviceAllocatedBytes).max(),
            latestDeviceAllocatedBytes: samples.last(where: { $0.deviceAllocatedBytes != nil })?.deviceAllocatedBytes
        )
    }

    // MARK: Recording

    /// Records the end of one draw call.
    func didDraw(_ outcome: BackgroundRenderOutcome?, declinedProduction: Bool) {
        state.withLock { state in
            state.counts.draws += 1
            switch outcome {
            case .submitted: state.counts.drawn += 1
            case .skipped: state.counts.skipped += 1
            case nil: state.counts.rejected += 1
            }
            if declinedProduction {
                state.counts.declinedProductions += 1
            }
        }
    }

    /// The CPU part of a sample, measured before commit.
    struct CPUCost: Sendable {
        var encode: Duration
        var produce: Duration
        var targetAcquisition: Duration
    }

    /// Counts a commit and adds a completed handler to `commandBuffer` that
    /// records its sample. Call just before committing it.
    func willCommit(
        _ commandBuffer: any MTLCommandBuffer, frameID: UInt64, drewFrame: Bool,
        cpu: CPUCost, deviceAllocatedBytes: Int?
    ) {
        let generation = state.withLock { state in
            state.counts.commandBuffersCommitted += 1
            return state.generation
        }
        commandBuffer.addCompletedHandler { [self] commandBuffer in
            let start = commandBuffer.gpuStartTime
            let end = commandBuffer.gpuEndTime
            let reportsGPUTime = start > 0 || end > 0
            record(Sample(
                frameID: frameID, drewFrame: drewFrame,
                encodeDuration: cpu.encode, produceDuration: cpu.produce,
                targetAcquisitionDuration: cpu.targetAcquisition,
                gpuStartTime: reportsGPUTime ? start : nil,
                gpuEndTime: reportsGPUTime ? end : nil,
                completed: commandBuffer.status == .completed,
                deviceAllocatedBytes: deviceAllocatedBytes
            ), generation: generation)
        }
    }

    /// Adds a sample to the window of `generation`, if it is still current.
    func record(_ sample: Sample, generation: Int? = nil) {
        state.withLock { state in
            if let generation, generation != state.generation { return }
            if sample.completed {
                state.counts.commandBuffersCompleted += 1
            } else {
                state.counts.commandBuffersFailed += 1
            }
            if state.ring.count < capacity {
                state.ring.append(sample)
            } else {
                state.ring[state.next] = sample
                state.next = (state.next + 1) % capacity
            }
        }
    }
}

/// Times one draw call on the CPU for a ``RenderMetrics`` recorder. Without a
/// recorder it passes every call through and reads no clock.
///
/// Used on the drawing thread only, for the duration of one draw call.
final class DrawTimer {
    private let metrics: RenderMetrics?
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant?
    private var produce = Duration.zero
    private var targetAcquisition = Duration.zero
    private var declinedProduction = false

    init(metrics: RenderMetrics?) {
        self.metrics = metrics
        start = metrics == nil ? nil : clock.now
    }

    /// Runs the app's producer, timing it.
    func produce(_ body: () -> BackgroundFrameLease?) -> BackgroundFrameLease? {
        guard metrics != nil else { return body() }
        let begin = clock.now
        let lease = body()
        produce += clock.now - begin
        declinedProduction = lease == nil
        return lease
    }

    /// Runs the host's target acquisition, timing it.
    func acquire(_ body: () -> BackgroundDrawTarget?) -> BackgroundDrawTarget? {
        guard metrics != nil else { return body() }
        let begin = clock.now
        let target = body()
        targetAcquisition += clock.now - begin
        return target
    }

    /// Ends the CPU measurement just before `commandBuffer` is committed.
    func willCommit(_ commandBuffer: any MTLCommandBuffer, frameID: UInt64, drewFrame: Bool, device: any MTLDevice) {
        guard let metrics, let start else { return }
        let cost = RenderMetrics.CPUCost(
            encode: clock.now - start - produce - targetAcquisition,
            produce: produce,
            targetAcquisition: targetAcquisition
        )
        let allocated = device.currentAllocatedSize
        metrics.willCommit(
            commandBuffer, frameID: frameID, drewFrame: drewFrame,
            cpu: cost, deviceAllocatedBytes: allocated > 0 ? allocated : nil
        )
    }

    /// Records the draw's outcome; `nil` when the produced frame was rejected.
    func finish(_ outcome: BackgroundRenderOutcome?) {
        metrics?.didDraw(outcome, declinedProduction: declinedProduction)
    }
}
