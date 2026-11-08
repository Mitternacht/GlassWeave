import Synchronization

/// What the producer learns when a frame's storage is safe to reuse.
///
/// Delivered exactly once per lease, including when every use was skipped or
/// cancelled.
public struct BackgroundFrameRelease: Hashable, Sendable {
    public let frameID: UInt64
    /// GPU submissions that sampled the frame and completed.
    public let completedSubmissions: Int
    /// GPU submissions that sampled the frame and finished with an error.
    public let failedSubmissions: Int
    /// Uses that were started and then skipped before any GPU work was
    /// committed (for example, no drawable was available).
    public let skippedSubmissions: Int
    /// Uses abandoned before commit (for example, an encoder could not be
    /// created, or the owner was torn down mid-use).
    public let cancelledSubmissions: Int
}

/// Ownership of one ``BackgroundFrame`` from hand-over until every consumer
/// is finished with its texture.
///
/// The lease is held by three kinds of owner:
/// - **The producer**, from creation until it calls ``retire()``, meaning it
///   will hand this frame to no further consumer.
/// - **Presenting surfaces**, while a renderer keeps the frame as its current
///   source (so it can redraw after a resize without a new frame).
/// - **GPU submissions**, from the start of encoding until the command buffer
///   completes, or until the use is skipped or cancelled.
///
/// When the last owner lets go, the lease is *released*: `onRelease` runs
/// exactly once and the producer may reuse the texture. A released lease
/// accepts no new owners. `onRelease` can run on any thread, including a
/// Metal completion thread; hop to your own isolation before touching state.
///
/// The texture itself stays alive while this object or any submitted command
/// buffer references it: the renderer encodes with retained-reference command
/// buffers, so Metal retains the texture until each submission completes.
public final class BackgroundFrameLease {
    public let frame: BackgroundFrame
    let core: LeaseCore

    public init(frame: BackgroundFrame, onRelease: @escaping @Sendable (BackgroundFrameRelease) -> Void) {
        self.frame = frame
        self.core = LeaseCore(frameID: frame.frameID, onRelease: onRelease)
    }

    /// The producer gives up its own hold. Call it once the frame has been
    /// handed to every consumer that should present it. Calling it again has
    /// no effect.
    public func retire() {
        core.retireProducer()
    }

    /// Whether the release has been reported and the storage may be reused.
    public var isReleased: Bool {
        core.isReleased
    }
}

/// The lease state machine, separate from locking so tests can drive it.
struct LeaseLedger: Hashable, Sendable {
    enum HoldEnd: Hashable, Sendable {
        case presentationEnded
        case submissionCompleted
        case submissionFailed
        case submissionSkipped
        case submissionCancelled
    }

    private(set) var producerHoldActive = true
    private(set) var consumerHolds = 0
    private(set) var completed = 0
    private(set) var failed = 0
    private(set) var skipped = 0
    private(set) var cancelled = 0
    private(set) var isReleased = false

    /// Adds a consumer hold. Fails once the lease is released.
    mutating func acquire() -> Bool {
        guard !isReleased else { return false }
        consumerHolds += 1
        return true
    }

    /// Drops the producer hold. Returns `true` if this released the lease.
    mutating func retireProducer() -> Bool {
        guard producerHoldActive else { return false }
        producerHoldActive = false
        return releaseIfUnowned()
    }

    /// Ends one consumer hold. Returns `true` if this released the lease.
    mutating func end(_ end: HoldEnd) -> Bool {
        precondition(consumerHolds > 0, "A lease hold ended more times than it was acquired")
        consumerHolds -= 1
        switch end {
        case .presentationEnded: break
        case .submissionCompleted: completed += 1
        case .submissionFailed: failed += 1
        case .submissionSkipped: skipped += 1
        case .submissionCancelled: cancelled += 1
        }
        return releaseIfUnowned()
    }

    func release(frameID: UInt64) -> BackgroundFrameRelease {
        BackgroundFrameRelease(
            frameID: frameID,
            completedSubmissions: completed,
            failedSubmissions: failed,
            skippedSubmissions: skipped,
            cancelledSubmissions: cancelled
        )
    }

    private mutating func releaseIfUnowned() -> Bool {
        guard !isReleased, !producerHoldActive, consumerHolds == 0 else { return false }
        isReleased = true
        return true
    }
}

/// The thread-safe part of a lease. GPU completion handlers capture only
/// this, never the texture.
final class LeaseCore: Sendable {
    let frameID: UInt64
    private let ledger = Mutex(LeaseLedger())
    private let onRelease: @Sendable (BackgroundFrameRelease) -> Void

    init(frameID: UInt64, onRelease: @escaping @Sendable (BackgroundFrameRelease) -> Void) {
        self.frameID = frameID
        self.onRelease = onRelease
    }

    var isReleased: Bool {
        ledger.withLock { $0.isReleased }
    }

    var snapshot: LeaseLedger {
        ledger.withLock { $0 }
    }

    /// Starts a consumer hold, or returns `nil` if the lease is released.
    func acquire(_ kind: LeaseHold.Kind) -> LeaseHold? {
        let acquired = ledger.withLock { $0.acquire() }
        return acquired ? LeaseHold(kind: kind, core: self) : nil
    }

    func retireProducer() {
        let release: BackgroundFrameRelease? = ledger.withLock { ledger in
            ledger.retireProducer() ? ledger.release(frameID: frameID) : nil
        }
        // Report outside the lock so the producer may call back into GlassWeave.
        if let release { onRelease(release) }
    }

    fileprivate func end(_ end: LeaseLedger.HoldEnd) {
        let release: BackgroundFrameRelease? = ledger.withLock { ledger in
            ledger.end(end) ? ledger.release(frameID: frameID) : nil
        }
        if let release { onRelease(release) }
    }
}

/// One consumer's claim on a lease. Ends exactly once: explicitly, or as
/// abandoned when the hold is deallocated without an explicit end.
final class LeaseHold: Sendable {
    enum Kind: Hashable, Sendable {
        case presentation
        case submission
    }

    enum SubmissionEnd: Hashable, Sendable {
        case completed
        case failed
        case skipped
        case cancelled
    }

    let kind: Kind
    private let core: LeaseCore
    private let ended = Atomic<Bool>(false)

    fileprivate init(kind: Kind, core: LeaseCore) {
        self.kind = kind
        self.core = core
    }

    /// Ends a presentation hold. Later calls have no effect.
    func endPresentation() {
        precondition(kind == .presentation, "endPresentation() called on a submission hold")
        finish(.presentationEnded)
    }

    /// Ends a submission hold with its outcome. Later calls have no effect.
    func end(_ outcome: SubmissionEnd) {
        precondition(kind == .submission, "end(_:) called on a presentation hold")
        switch outcome {
        case .completed: finish(.submissionCompleted)
        case .failed: finish(.submissionFailed)
        case .skipped: finish(.submissionSkipped)
        case .cancelled: finish(.submissionCancelled)
        }
    }

    var hasEnded: Bool {
        ended.load(ordering: .acquiring)
    }

    private func finish(_ end: LeaseLedger.HoldEnd) {
        let (exchanged, _) = ended.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing)
        if exchanged { core.end(end) }
    }

    deinit {
        // A hold dropped without an explicit end still releases its claim, so
        // the producer always hears back exactly once.
        switch kind {
        case .presentation: finish(.presentationEnded)
        case .submission: finish(.submissionCancelled)
        }
    }
}
