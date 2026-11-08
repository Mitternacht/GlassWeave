import Testing
@testable import GlassWeave

/// The lease state machine and its thread-safe wrapper: who owns a frame,
/// when it is released, and that release is reported exactly once.
struct LeaseLedgerTests {
    @Test func `Retiring an unowned lease releases it immediately`() {
        var ledger = LeaseLedger()
        #expect(!ledger.isReleased)
        let released = ledger.retireProducer()
        #expect(released)
        #expect(ledger.isReleased)
    }

    @Test func `Consumer holds keep the lease after the producer retires`() {
        var ledger = LeaseLedger()
        let acquired = [ledger.acquire(), ledger.acquire()]
        #expect(acquired == [true, true])
        let releasedByRetire = ledger.retireProducer()
        #expect(!releasedByRetire)
        let releasedByPresentationEnd = ledger.end(.presentationEnded)
        #expect(!releasedByPresentationEnd)
        #expect(!ledger.isReleased)
        let releasedByLastSubmission = ledger.end(.submissionCompleted)
        #expect(releasedByLastSubmission)
        #expect(ledger.isReleased)
    }

    @Test func `Consumers alone do not release while the producer still holds`() {
        var ledger = LeaseLedger()
        let acquired = ledger.acquire()
        #expect(acquired)
        let releasedBySubmission = ledger.end(.submissionCompleted)
        #expect(!releasedBySubmission)
        #expect(!ledger.isReleased)
        let releasedByRetire = ledger.retireProducer()
        #expect(releasedByRetire)
    }

    @Test func `Retiring twice changes nothing`() {
        var ledger = LeaseLedger()
        _ = ledger.acquire()
        let first = ledger.retireProducer()
        #expect(!first)
        let afterFirst = ledger
        let second = ledger.retireProducer()
        #expect(!second)
        #expect(ledger == afterFirst)
    }

    @Test func `A released lease accepts no new holds`() {
        var ledger = LeaseLedger()
        _ = ledger.retireProducer()
        let acquired = ledger.acquire()
        #expect(!acquired)
        #expect(ledger.consumerHolds == 0)
    }

    @Test func `Release counts each submission outcome`() {
        var ledger = LeaseLedger()
        for _ in 0..<7 { _ = ledger.acquire() }
        #expect(ledger.consumerHolds == 7)
        _ = ledger.retireProducer()
        let ends: [LeaseLedger.HoldEnd] = [
            .submissionCompleted, .submissionCompleted, .submissionFailed,
            .submissionSkipped, .submissionCancelled, .submissionCancelled,
        ]
        let releasedEarly = ends.map { ledger.end($0) }
        #expect(releasedEarly == Array(repeating: false, count: 6))
        let releasedLast = ledger.end(.presentationEnded)
        #expect(releasedLast)
        #expect(ledger.release(frameID: 42) == BackgroundFrameRelease(
            frameID: 42, completedSubmissions: 2, failedSubmissions: 1,
            skippedSubmissions: 1, cancelledSubmissions: 2
        ))
    }
}

struct LeaseCoreTests {
    @Test func `Release is reported once, after the last owner lets go`() {
        let recorder = ReleaseRecorder()
        let core = LeaseCore(frameID: 9, onRelease: recorder.handler)
        let presentation = core.acquire(.presentation)
        let submission = core.acquire(.submission)
        core.retireProducer()
        #expect(recorder.releases.isEmpty)
        presentation?.endPresentation()
        #expect(recorder.releases.isEmpty)
        submission?.end(.completed)
        #expect(recorder.releases == [BackgroundFrameRelease(
            frameID: 9, completedSubmissions: 1, failedSubmissions: 0,
            skippedSubmissions: 0, cancelledSubmissions: 0
        )])
        #expect(core.isReleased)
        #expect(core.acquire(.submission) == nil)
        core.retireProducer()
        #expect(recorder.releases.count == 1)
    }

    @Test func `Ending a hold twice counts once`() throws {
        let recorder = ReleaseRecorder()
        let core = LeaseCore(frameID: 1, onRelease: recorder.handler)
        let first = try #require(core.acquire(.submission))
        let second = try #require(core.acquire(.submission))
        core.retireProducer()
        first.end(.skipped)
        first.end(.completed)
        #expect(first.hasEnded)
        #expect(core.snapshot.consumerHolds == 1)
        #expect(recorder.releases.isEmpty)
        second.end(.completed)
        #expect(recorder.releases.map(\.skippedSubmissions) == [1])
        #expect(recorder.releases.map(\.completedSubmissions) == [1])
    }

    @Test func `Dropping a submission hold without ending it cancels the use`() {
        let recorder = ReleaseRecorder()
        let core = LeaseCore(frameID: 3, onRelease: recorder.handler)
        var hold = core.acquire(.submission)
        core.retireProducer()
        #expect(hold != nil)
        hold = nil
        #expect(recorder.releases.map(\.cancelledSubmissions) == [1])
    }

    @Test func `Dropping a presentation hold ends the presentation`() {
        let recorder = ReleaseRecorder()
        let core = LeaseCore(frameID: 4, onRelease: recorder.handler)
        var hold = core.acquire(.presentation)
        core.retireProducer()
        #expect(hold != nil && recorder.releases.isEmpty)
        hold = nil
        #expect(recorder.releases == [BackgroundFrameRelease(
            frameID: 4, completedSubmissions: 0, failedSubmissions: 0,
            skippedSubmissions: 0, cancelledSubmissions: 0
        )])
    }

    @Test func `Concurrent completions report exactly one release`() async throws {
        let recorder = ReleaseRecorder()
        let core = LeaseCore(frameID: 77, onRelease: recorder.handler)
        var holds: [LeaseHold] = []
        for _ in 0..<1_000 {
            holds.append(try #require(core.acquire(.submission)))
        }
        core.retireProducer()
        await withTaskGroup(of: Void.self) { group in
            for hold in holds {
                group.addTask {
                    hold.end(.completed)
                    hold.end(.failed)
                }
            }
        }
        #expect(recorder.releases.count == 1)
        #expect(recorder.releases.first?.completedSubmissions == 1_000)
        #expect(recorder.releases.first?.failedSubmissions == 0)
    }
}
