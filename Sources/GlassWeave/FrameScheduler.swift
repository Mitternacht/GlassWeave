import Synchronization

/// Counts of what one host's frame scheduler did, for diagnostics, tests,
/// and lifecycle traces.
///
/// A *request* says something changed (new content, a resize, a new panel).
/// A *draw* is one display pass that may commit GPU work. Requests made
/// before the next permitted draw merge into one pending draw, so the counts
/// describe both how much was asked for and how much GPU work resulted.
public struct FrameStatistics: Hashable, Sendable {
    /// Requests for a new frame.
    public var requested = 0
    /// Requests that arrived while a draw was already pending and merged into
    /// it.
    public var coalesced = 0
    /// Draws that committed GPU work to the command queue.
    public var submitted = 0
    /// Submitted draws whose GPU work has completed.
    public var completed = 0
    /// Draws that started but committed no GPU work (no source, a zero-size
    /// target, or no drawable while nothing was produced).
    public var skipped = 0
    /// Requests and draws that found the host not visible. The frame stays
    /// pending and is drawn once, when the host is visible again.
    public var deferredWhileHidden = 0
    /// Draws that found the in-flight bound reached. The frame stays pending
    /// and is drawn once, when a frame in flight completes.
    public var deferredAtLimit = 0
    /// Frames committed and not yet completed.
    public var framesInFlight = 0
    /// The most frames that were in flight at once.
    public var peakFramesInFlight = 0

    public init() {}
}

/// The scheduler's answer when a display pass is about to draw.
package enum FrameDrawDecision: Hashable, Sendable {
    /// Draw now. One in-flight slot is reserved; end it with
    /// ``FrameScheduler/drawCommitted()`` or ``FrameScheduler/drawSkipped()``.
    case draw
    /// The host is not visible. The frame stays pending.
    case deferredWhileHidden
    /// ``FrameLedger/maxFramesInFlight`` frames are in flight. The frame stays
    /// pending and is drawn when one completes.
    case deferredAtLimit
    /// No frame was requested since the last draw, so the pass draws
    /// nothing: a display pass the host did not ask for, or a second pass
    /// for a request an earlier pass already drew.
    case nothingPending
}

/// The scheduling state machine of one host, separate from locking so tests
/// can drive every transition directly.
///
/// The policy:
/// - **On demand.** Nothing is drawn unless something requested a frame.
///   A display pass with no pending request draws nothing, so a stationary
///   source with a settled surface submits nothing however many passes run.
/// - **Coalesced.** Any number of requests before the next permitted draw
///   become one pending draw.
/// - **Visibility.** While the host is not visible, requests and draws are
///   deferred; the pending frame is drawn once when the host becomes visible.
///   Visibility belongs to one host, never to the process.
/// - **Bounded.** At most ``maxFramesInFlight`` frames are committed and not
///   yet completed. A draw at the bound is deferred (never queued and never
///   waited for); the pending frame is drawn when a frame completes.
package struct FrameLedger: Hashable, Sendable {
    package let maxFramesInFlight: Int
    package private(set) var isVisible: Bool
    /// A frame was requested and has not been drawn yet.
    package private(set) var hasPendingFrame = false
    package private(set) var statistics = FrameStatistics()
    /// A draw reserved a slot and has not reported commit or skip yet.
    private var drawInProgress = false

    package init(maxFramesInFlight: Int, isVisible: Bool) {
        precondition(maxFramesInFlight > 0, "At least one frame must be allowed in flight")
        self.maxFramesInFlight = maxFramesInFlight
        self.isVisible = isVisible
    }

    /// Records a request. Returns `true` when the host should schedule a
    /// display pass now; `false` while hidden or at the in-flight bound, when
    /// visibility or a completion schedules it later.
    package mutating func request() -> Bool {
        statistics.requested += 1
        if hasPendingFrame {
            statistics.coalesced += 1
        }
        hasPendingFrame = true
        guard isVisible else {
            statistics.deferredWhileHidden += 1
            return false
        }
        return statistics.framesInFlight < maxFramesInFlight
    }

    /// Decides whether a display pass may draw. A permitted draw reserves an
    /// in-flight slot and consumes the pending request; a pass with nothing
    /// pending draws nothing and changes nothing.
    package mutating func beginDraw() -> FrameDrawDecision {
        precondition(!drawInProgress, "A draw began before the previous one ended")
        guard hasPendingFrame else {
            return .nothingPending
        }
        guard isVisible else {
            statistics.deferredWhileHidden += 1
            return .deferredWhileHidden
        }
        guard statistics.framesInFlight < maxFramesInFlight else {
            statistics.deferredAtLimit += 1
            return .deferredAtLimit
        }
        hasPendingFrame = false
        drawInProgress = true
        statistics.framesInFlight += 1
        statistics.peakFramesInFlight = max(statistics.peakFramesInFlight, statistics.framesInFlight)
        return .draw
    }

    /// The permitted draw committed GPU work; its slot stays reserved until
    /// ``frameCompleted()``.
    package mutating func drawCommitted() {
        precondition(drawInProgress, "No draw is in progress")
        drawInProgress = false
        statistics.submitted += 1
    }

    /// The permitted draw committed nothing; its slot is free again.
    ///
    /// Returns `true` when a frame is pending and can be drawn now, so the
    /// host should schedule a display pass. That happens when a request
    /// arrived during the draw (from the producer or an observer) and found
    /// the slot this draw had reserved, or a completion arrived during the
    /// draw: both left the wake-up to the end of the draw, and a skipped
    /// draw has no completion of its own to deliver it.
    package mutating func drawSkipped() -> Bool {
        precondition(drawInProgress, "No draw is in progress")
        drawInProgress = false
        statistics.skipped += 1
        statistics.framesInFlight -= 1
        return hasPendingFrame && isVisible && statistics.framesInFlight < maxFramesInFlight
    }

    /// A committed frame's GPU work completed. Returns `true` when a pending
    /// frame can now be drawn and the host should schedule a display pass.
    package mutating func frameCompleted() -> Bool {
        precondition(statistics.framesInFlight > (drawInProgress ? 1 : 0), "A frame completed that was never committed")
        statistics.framesInFlight -= 1
        statistics.completed += 1
        return hasPendingFrame && isVisible && !drawInProgress
    }

    /// Updates visibility. Returns `true` when the host became visible with a
    /// pending frame it can draw now.
    package mutating func setVisible(_ visible: Bool) -> Bool {
        let wasVisible = isVisible
        isVisible = visible
        return visible && !wasVisible && hasPendingFrame
            && statistics.framesInFlight < maxFramesInFlight
    }
}

/// The thread-safe scheduler one host owns. Requests, draws, and visibility
/// come from the host's isolation domain; completions come from Metal's
/// completion threads. GPU completion handlers capture only this object.
package final class FrameScheduler: Sendable {
    /// Frames a host may have committed and not yet completed.
    ///
    /// Two leaves one of a `CAMetalLayer`'s default three drawables free for
    /// the next draw while one is on screen, so acquiring it does not wait
    /// for GPU work (it can still wait for the next display refresh if a
    /// completed frame has not been presented yet). It is also the bound the
    /// laboratory's three-texture source pool is sized for: one current
    /// frame plus the frames still in flight.
    package static let defaultMaxFramesInFlight = 2

    private let ledger: Mutex<FrameLedger>

    package init(maxFramesInFlight: Int = FrameScheduler.defaultMaxFramesInFlight, isVisible: Bool) {
        ledger = Mutex(FrameLedger(maxFramesInFlight: maxFramesInFlight, isVisible: isVisible))
    }

    package var snapshot: FrameLedger {
        ledger.withLock { $0 }
    }

    package var statistics: FrameStatistics {
        ledger.withLock { $0.statistics }
    }

    package func request() -> Bool {
        ledger.withLock { $0.request() }
    }

    package func beginDraw() -> FrameDrawDecision {
        ledger.withLock { $0.beginDraw() }
    }

    /// The permitted draw committed nothing. Returns `true` when a pending
    /// frame can be drawn now: schedule a display pass.
    package func drawSkipped() -> Bool {
        ledger.withLock { $0.drawSkipped() }
    }

    package func setVisible(_ visible: Bool) -> Bool {
        ledger.withLock { $0.setVisible(visible) }
    }

    /// The permitted draw committed GPU work. Call it before committing,
    /// and call ``frameCompleted()`` from that command buffer's completed
    /// handler.
    package func drawCommitted() {
        ledger.withLock { $0.drawCommitted() }
    }

    /// A committed frame completed. Returns `true` when a pending frame can
    /// now be drawn: hop to the host's isolation domain and schedule a
    /// display pass. Safe to call from a Metal completion thread.
    package func frameCompleted() -> Bool {
        ledger.withLock { $0.frameCompleted() }
    }
}
