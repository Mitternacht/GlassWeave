import CoreGraphics
import Foundation
import Testing
@testable import GlassWeave

/// GW-32's safety test: the proximity-to-progress function that drives a merge
/// is deterministic, monotonic in the gap, clamped to 0...1 and has hysteresis
/// (the same gap gives a different progress depending on the previous state),
/// and a pair that hovers at a threshold does not flicker.
@Suite(.timeLimit(.minutes(1)))
struct GlassProximityMergeTests {
    @Test func proximityProgressIsDeterministicMonotonicClampedAndHasHysteresis() throws {
        let merge = GlassProximityMerge.standard
        let gaps = stride(from: -60.0, through: 200.0, by: 0.25).map { $0 }

        for isMerged in [false, true] {
            var previous = Double.infinity
            for gap in gaps {
                let progress = try merge.progress(gap: gap, isMerged: isMerged)
                // Deterministic: the same input gives the same value.
                #expect(progress == (try merge.progress(gap: gap, isMerged: isMerged)))
                // Clamped.
                #expect((0...1).contains(progress))
                // Monotonic: a larger gap never gives a larger progress.
                #expect(progress <= previous)
                previous = progress
            }
            // The ends: fully merged inside the full gap, apart beyond the start.
            let shift = isMerged ? merge.release : 0
            #expect(try merge.progress(gap: merge.fullGap + shift - 1, isMerged: isMerged) == 1)
            #expect(try merge.progress(gap: merge.startGap + shift + 1, isMerged: isMerged) == 0)
        }

        // Hysteresis: between the thresholds a merged pair holds on to more
        // progress than an apart pair at the same gap, and they agree outside.
        for gap in gaps {
            let apart = try merge.progress(gap: gap, isMerged: false)
            let merged = try merge.progress(gap: gap, isMerged: true)
            #expect(merged >= apart)
            if gap <= merge.fullGap || gap >= merge.startGap + merge.release {
                #expect(merged == apart)
            }
        }
        let middle = (merge.fullGap + merge.startGap + merge.release) / 2
        #expect(try merge.progress(gap: middle, isMerged: true) > (try merge.progress(gap: middle, isMerged: false)))

        // The state flips at the thresholds only, and the two curves meet
        // there, so progress never jumps when it does.
        #expect(try merge.isMerged(afterGap: merge.fullGap, wasMerged: false))
        #expect(try !merge.isMerged(afterGap: merge.fullGap + 0.01, wasMerged: false))
        #expect(try merge.isMerged(afterGap: merge.startGap + merge.release - 0.01, wasMerged: true))
        #expect(try !merge.isMerged(afterGap: merge.startGap + merge.release, wasMerged: true))
        #expect(try merge.progress(gap: merge.fullGap, isMerged: false) == merge.progress(gap: merge.fullGap, isMerged: true))
        #expect(try merge.progress(gap: merge.startGap + merge.release, isMerged: true) == merge.progress(gap: merge.startGap + merge.release, isMerged: false))

        // Followed over time, a pair that is brought in, then pulled out to the
        // same gap, differs from a pair that never merged; a finger hovering
        // at the release threshold flips the state at most once.
        let pill = GlassProximityMerge.Outline.panel(frame: CGRect(x: 0, y: 0, width: 148, height: 56), cornerRadius: 28)
        func round(gap: Double) -> GlassProximityMerge.Outline {
            .panel(frame: CGRect(x: 148 + gap, y: -4, width: 64, height: 64), cornerRadius: 32)
        }
        let probe = 24.0
        var visited = GlassProximityMerge.Tracker()
        for gap in stride(from: 80.0, through: 0.0, by: -4.0) { try visited.update([pill, round(gap: gap)]) }
        for gap in stride(from: 0.0, through: probe, by: 4.0) { try visited.update([pill, round(gap: gap)]) }
        var fresh = GlassProximityMerge.Tracker()
        try fresh.update([pill, round(gap: probe)])
        #expect(visited.pairs[0].gap == fresh.pairs[0].gap)
        #expect(visited.pairs[0].isMerged && !fresh.pairs[0].isMerged)
        #expect(visited.pairs[0].progress > fresh.pairs[0].progress)

        var hover = GlassProximityMerge.Tracker()
        var flips = 0
        var last = false
        func feed(_ gap: Double) throws {
            try hover.update([pill, round(gap: gap)])
            if hover.pairs[0].isMerged != last { flips += 1; last = hover.pairs[0].isMerged }
        }
        // Hovering across the merge threshold merges once and stays merged.
        for step in 0..<50 { try feed(merge.fullGap + (step.isMultiple(of: 2) ? 0.8 : -0.8)) }
        #expect(flips == 1)
        // Hovering across the release threshold lets go once and stays apart.
        let edge = merge.startGap + merge.release
        for step in 0..<50 { try feed(edge + (step.isMultiple(of: 2) ? -0.8 : 0.8)) }
        #expect(flips == 2)

        // A NaN or infinite value is rejected by name; a finite one clamps.
        #expect(throws: GlassProximityMergeError.nonFinite(.gap)) { try merge.progress(gap: .nan, isMerged: false) }
        #expect(throws: GlassProximityMergeError.nonFinite(.startGap)) { try GlassProximityMerge(startGap: .infinity) }
        #expect(try GlassProximityMerge(startGap: 9999, fullGap: -9999, release: -5, blend: 9999, interiorBlend: -1)
            == GlassProximityMerge(startGap: 400, fullGap: -100, release: 0, blend: 400, interiorBlend: 0))
    }
}
