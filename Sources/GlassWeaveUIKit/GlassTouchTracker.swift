#if canImport(UIKit)
import CoreGraphics
import GlassWeave

/// The touches a ``GlassSurfaceView`` is answering (GW-12): up to
/// ``GlassTouch/maximumTouchCount`` fingers, each with the effect-clock time
/// it began and ended. Pure bookkeeping; the surface owns the clock, the pacing
/// and the drawing.
struct GlassTouchTracker {
    struct Entry: Equatable {
        var id: Int
        var point: GlassTouchPoint
    }

    private(set) var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }
    var points: [GlassTouchPoint] { entries.map(\.point) }

    /// Starts a touch at `time`. Returns `false` when there is no room: two
    /// touches are live (down, or still fading) and none has ended. A touch
    /// that has ended makes room for a new one, oldest first.
    mutating func begin(id: Int, at location: CGPoint, time: Double) -> Bool {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries.remove(at: index)
        }
        if entries.count >= GlassTouch.maximumTouchCount {
            guard let ended = entries.firstIndex(where: { $0.point.endedAt != nil }) else { return false }
            entries.remove(at: ended)
        }
        entries.append(Entry(id: id, point: GlassTouchPoint(origin: location, beganAt: time)))
        return true
    }

    /// Moves a touch that is down. Returns whether there was one.
    mutating func move(id: Int, to location: CGPoint) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.point.endedAt == nil }) else { return false }
        entries[index].point.position = location
        return true
    }

    /// Ends a touch that is down at `time`. Returns whether there was one.
    mutating func end(id: Int, time: Double) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.point.endedAt == nil }) else { return false }
        entries[index].point.endedAt = time
        return true
    }

    /// Removes the touches that show nothing any more under every one of
    /// `styles` at `time`; returns how many.
    mutating func removeSettled(styles: [GlassTouch], time: Double) -> Int {
        let before = entries.count
        entries.removeAll { entry in
            styles.allSatisfy { $0.state(of: entry.point, at: time).isSettled }
        }
        return before - entries.count
    }

    /// Removes every touch; returns how many.
    mutating func removeAll() -> Int {
        let before = entries.count
        entries.removeAll()
        return before
    }

    /// Whether any touch still changes with time under one of `styles`: a ring
    /// travelling, a light fading in or out.
    func isAnimating(styles: [GlassTouch], time: Double) -> Bool {
        entries.contains { entry in
            styles.contains { $0.isAnimated && !$0.state(of: entry.point, at: time).isSteady }
        }
    }
}
#endif
