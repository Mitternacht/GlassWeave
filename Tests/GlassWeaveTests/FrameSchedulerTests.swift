import Dispatch
import Synchronization
import Testing
@testable import GlassWeave

/// The frame scheduler's state machine: on-demand drawing, coalescing,
/// per-host visibility, and the in-flight bound.
struct FrameLedgerTests {
    /// Runs one permitted draw that commits GPU work.
    private func drawAndCommit(_ ledger: inout FrameLedger) {
        #expect(ledger.beginDraw() == .draw)
        ledger.drawCommitted()
    }

    @Test func `A request asks for one draw, which consumes it`() {
        var ledger = FrameLedger(maxFramesInFlight: 2, isVisible: true)
        #expect(!ledger.hasPendingFrame)
        let schedule = ledger.request()
        #expect(schedule)
        #expect(ledger.hasPendingFrame)
        drawAndCommit(&ledger)
        #expect(!ledger.hasPendingFrame)
        let drawAgain = ledger.frameCompleted()
        #expect(!drawAgain, "A settled host has nothing left to draw")
        #expect(ledger.statistics.requested == 1)
        #expect(ledger.statistics.submitted == 1)
        #expect(ledger.statistics.completed == 1)
        #expect(ledger.statistics.framesInFlight == 0)
    }

    @Test func `Requests before the next draw coalesce into one`() {
        var ledger = FrameLedger(maxFramesInFlight: 2, isVisible: true)
        for _ in 0..<5 { _ = ledger.request() }
        #expect(ledger.statistics.requested == 5)
        #expect(ledger.statistics.coalesced == 4)
        drawAndCommit(&ledger)
        #expect(!ledger.hasPendingFrame)
        #expect(ledger.statistics.submitted == 1)
    }

    @Test func `A hidden host defers requests and draws once when shown`() {
        var ledger = FrameLedger(maxFramesInFlight: 2, isVisible: false)
        let schedules = (0..<3).map { _ in ledger.request() }
        #expect(schedules == [false, false, false])
        // A display pass that still arrives while hidden draws nothing.
        #expect(ledger.beginDraw() == .deferredWhileHidden)
        #expect(ledger.statistics.deferredWhileHidden == 4)
        #expect(ledger.statistics.framesInFlight == 0)

        let drawOnShow = ledger.setVisible(true)
        #expect(drawOnShow)
        drawAndCommit(&ledger)
        #expect(!ledger.hasPendingFrame)
        let showAgain = ledger.setVisible(true)
        #expect(!showAgain, "Already visible")
        #expect(ledger.statistics.submitted == 1)
    }

    @Test func `Showing a host with nothing pending draws nothing`() {
        var ledger = FrameLedger(maxFramesInFlight: 2, isVisible: false)
        let drawOnShow = ledger.setVisible(true)
        #expect(!drawOnShow)
    }

    @Test func `The in-flight bound defers a draw until a frame completes`() {
        var ledger = FrameLedger(maxFramesInFlight: 2, isVisible: true)
        drawAndCommit(&ledger)
        drawAndCommit(&ledger)
        #expect(ledger.statistics.framesInFlight == 2)
        let schedule = ledger.request()
        #expect(!schedule, "At the bound, a request waits for a completion")
        #expect(ledger.beginDraw() == .deferredAtLimit)
        #expect(ledger.statistics.framesInFlight == 2)
        #expect(ledger.hasPendingFrame)

        let drawAfterCompletion = ledger.frameCompleted()
        #expect(drawAfterCompletion)
        drawAndCommit(&ledger)
        #expect(ledger.statistics.peakFramesInFlight == 2)
        #expect(ledger.statistics.deferredAtLimit == 1)
    }

    @Test func `A skipped draw frees its slot without a completion`() {
        var ledger = FrameLedger(maxFramesInFlight: 1, isVisible: true)
        #expect(ledger.beginDraw() == .draw)
        ledger.drawSkipped()
        #expect(ledger.statistics.framesInFlight == 0)
        #expect(ledger.statistics.skipped == 1)
        #expect(ledger.beginDraw() == .draw)
    }

    @Test func `Completions while hidden keep the frame pending until shown`() {
        var ledger = FrameLedger(maxFramesInFlight: 2, isVisible: true)
        drawAndCommit(&ledger)
        drawAndCommit(&ledger)
        _ = ledger.request()
        _ = ledger.setVisible(false)
        let first = ledger.frameCompleted()
        let second = ledger.frameCompleted()
        #expect(!first && !second, "Nothing draws while hidden")
        #expect(ledger.hasPendingFrame)
        let drawOnShow = ledger.setVisible(true)
        #expect(drawOnShow)
    }

    @Test func `Showing a host at the bound leaves the draw to the next completion`() {
        var ledger = FrameLedger(maxFramesInFlight: 1, isVisible: true)
        drawAndCommit(&ledger)
        _ = ledger.setVisible(false)
        _ = ledger.request()
        let drawOnShow = ledger.setVisible(true)
        #expect(!drawOnShow)
        let drawAfterCompletion = ledger.frameCompleted()
        #expect(drawAfterCompletion)
    }

    /// A long seeded sequence of every operation keeps the invariants: never
    /// more than the bound in flight, every submitted frame either completed
    /// or still in flight, and a pending frame never lost.
    @Test(arguments: [1, 2, 3])
    func `Random operation sequences keep the bound and lose no pending frame`(maxFramesInFlight: Int) {
        var generator = SplitMix64(seed: UInt64(maxFramesInFlight) * 0x9E37_79B9)
        var ledger = FrameLedger(maxFramesInFlight: maxFramesInFlight, isVisible: true)
        var displayPassScheduled = false
        for _ in 0..<5_000 {
            switch generator.next() % 5 {
            case 0:
                if ledger.request() { displayPassScheduled = true }
            case 1:
                // A display pass runs whether or not one was scheduled.
                displayPassScheduled = false
                if ledger.beginDraw() == .draw {
                    if generator.next() % 4 == 0 { ledger.drawSkipped() } else { ledger.drawCommitted() }
                }
            case 2:
                if ledger.statistics.framesInFlight > 0, ledger.frameCompleted() {
                    displayPassScheduled = true
                }
            case 3:
                if ledger.setVisible(generator.next() % 3 != 0) { displayPassScheduled = true }
            default:
                break
            }
            let statistics = ledger.statistics
            #expect(statistics.framesInFlight >= 0 && statistics.framesInFlight <= maxFramesInFlight)
            #expect(statistics.submitted == statistics.completed + statistics.framesInFlight)
            // Liveness: a pending frame on a visible host always has a
            // display pass scheduled or a completion that will schedule one.
            if ledger.hasPendingFrame, ledger.isVisible {
                #expect(displayPassScheduled || statistics.framesInFlight > 0)
            }
        }
    }
}

/// The thread-safe scheduler: completions arrive from many threads.
struct FrameSchedulerTests {
    @Test func `Concurrent completions end every frame exactly once`() {
        let frames = 1_000
        let scheduler = FrameScheduler(maxFramesInFlight: frames, isVisible: true)
        for _ in 0..<frames {
            #expect(scheduler.beginDraw() == .draw)
            scheduler.drawCommitted()
        }
        _ = scheduler.request()
        let redraws = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: frames) { _ in
            if scheduler.frameCompleted() {
                redraws.withLock { $0 += 1 }
            }
        }
        let statistics = scheduler.statistics
        #expect(statistics.framesInFlight == 0)
        #expect(statistics.completed == frames)
        #expect(statistics.peakFramesInFlight == frames)
        // The pending frame was below the bound the whole time, so every
        // completion reports it; the host coalesces those into one pass.
        #expect(redraws.withLock { $0 } == frames)
    }
}

/// A small deterministic generator, so a failing sequence can be replayed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The texture pool's bookkeeping: a fixed bound, reuse only after return,
/// and discarding on resize and trim.
struct TexturePoolLedgerTests {
    @Test func `Checkouts allocate up to the capacity, then report exhaustion`() {
        var ledger = TexturePoolLedger(capacity: 3)
        let checkouts = (0..<4).map { _ in ledger.checkout(width: 8, height: 8) }
        #expect(checkouts == [.allocate(0), .allocate(1), .allocate(2), .exhausted])
        #expect(ledger.allocations == 3)
        #expect(ledger.exhaustedCheckouts == 1)
        #expect(ledger.slots.count == 3)
    }

    @Test func `A returned texture is reused instead of allocating`() {
        var ledger = TexturePoolLedger(capacity: 2)
        _ = ledger.checkout(width: 8, height: 8)
        _ = ledger.checkout(width: 8, height: 8)
        ledger.didReturn(id: 1)
        #expect(ledger.checkout(width: 8, height: 8) == .reuse(1))
        #expect(ledger.allocations == 2)
        #expect(ledger.checkouts == 3)
    }

    @Test func `A new size discards free textures now and textures in use on return`() {
        var ledger = TexturePoolLedger(capacity: 3)
        _ = ledger.checkout(width: 8, height: 8)   // 0, stays in use
        _ = ledger.checkout(width: 8, height: 8)   // 1
        ledger.didReturn(id: 1)
        #expect(ledger.checkout(width: 16, height: 8) == .allocate(2))
        #expect(ledger.discarded == 1, "The free 8 x 8 texture is gone")
        #expect(ledger.slots.map(\.id) == [0, 2])
        // The in-use 8 x 8 texture still counts toward the capacity...
        #expect(ledger.checkout(width: 16, height: 8) == .allocate(3))
        #expect(ledger.checkout(width: 16, height: 8) == .exhausted)
        // ...and is discarded, not reused, when its frame is released.
        ledger.didReturn(id: 0)
        #expect(ledger.slots.map(\.id) == [2, 3])
        #expect(ledger.discarded == 2)
        #expect(ledger.checkout(width: 16, height: 8) == .allocate(4))
    }

    @Test func `Trim discards free textures now and textures in use on return`() {
        var ledger = TexturePoolLedger(capacity: 3)
        _ = ledger.checkout(width: 8, height: 8)   // 0, stays in use
        _ = ledger.checkout(width: 8, height: 8)   // 1
        ledger.didReturn(id: 1)
        ledger.trim()
        #expect(ledger.slots.map(\.id) == [0])
        ledger.didReturn(id: 0)
        #expect(ledger.slots.isEmpty)
        #expect(ledger.discarded == 2)
        #expect(ledger.checkout(width: 8, height: 8) == .allocate(2))
    }

    @Test func `Returns are idempotent and unknown IDs are ignored`() {
        var ledger = TexturePoolLedger(capacity: 2)
        _ = ledger.checkout(width: 8, height: 8)
        ledger.didReturn(id: 0)
        let afterFirst = ledger
        ledger.didReturn(id: 0)
        ledger.didReturn(id: 42)
        #expect(ledger == afterFirst)
    }

    @Test func `A failed allocation gives its slot back`() {
        var ledger = TexturePoolLedger(capacity: 1)
        #expect(ledger.checkout(width: 8, height: 8) == .allocate(0))
        ledger.allocationFailed(id: 0)
        #expect(ledger.slots.isEmpty)
        #expect(ledger.allocations == 0)
        #expect(ledger.checkout(width: 8, height: 8) == .allocate(1))
    }

    @Test func `Random checkouts, returns, resizes, and trims never exceed the capacity`() {
        var generator = SplitMix64(seed: 7)
        var ledger = TexturePoolLedger(capacity: 3)
        var inUse: [Int] = []
        let sizes = [(8, 8), (16, 8), (8, 16)]
        for _ in 0..<5_000 {
            switch generator.next() % 4 {
            case 0, 1:
                let size = sizes[Int(generator.next() % 3)]
                switch ledger.checkout(width: size.0, height: size.1) {
                case let .reuse(id), let .allocate(id): inUse.append(id)
                case .exhausted: #expect(ledger.slots.filter(\.inUse).count == 3)
                }
            case 2:
                if !inUse.isEmpty {
                    ledger.didReturn(id: inUse.remove(at: Int(generator.next() % UInt64(inUse.count))))
                }
            default:
                if generator.next() % 8 == 0 { ledger.trim() }
            }
            #expect(ledger.slots.count <= 3)
            #expect(Set(ledger.slots.filter(\.inUse).map(\.id)) == Set(inUse))
        }
    }
}
