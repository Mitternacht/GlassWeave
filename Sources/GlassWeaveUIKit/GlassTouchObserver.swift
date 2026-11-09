#if canImport(UIKit)
import GlassWeave
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Forwards the touches that land on a view to a ``GlassSurfaceView`` so its
/// glass can answer them (GW-12), without taking part in them.
///
/// > Important: Experimental. This API may change before a stable release.
///
/// The surface takes no touches (native controls above it own them), so an app
/// that wants the touch response attaches one observer to the stage or to any
/// ancestor of the glass and the controls:
///
/// ```swift
/// stage.addGestureRecognizer(GlassTouchObserver(surface: surface))
/// ```
///
/// The observer never changes how native content behaves:
///
/// - It never recognizes: its state stays `possible` until the last touch
///   ends or is cancelled, then it fails, so it never claims a touch, never
///   cancels one in its view (`cancelsTouchesInView` is `false`), and never
///   delays one (`delaysTouchesBegan`, `delaysTouchesEnded` are `false`).
/// - It never blocks a recognizer and is never blocked: it asks to recognize
///   simultaneously with every other recognizer and neither requires another to
///   fail nor is required to fail by it, and it receives every touch.
/// - A button inside the glass keeps its tap and its cancellation, because its
///   own touch tracking is untouched.
///
/// Each touch is forwarded to ``GlassSurfaceView/beginTouch(id:at:)``,
/// ``GlassSurfaceView/moveTouch(id:to:)`` and ``GlassSurfaceView/endTouch(id:)``
/// or ``GlassSurfaceView/cancelTouch(id:)``, with its location in the surface's
/// space. The surface answers two touches at most and ignores the rest.
@MainActor
public final class GlassTouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private weak var surface: GlassSurfaceView?
    /// The id the surface knows each live touch by.
    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextID = 0

    /// - Parameter surface: The surface that answers the touches. The observer
    ///   holds it weakly.
    public init(surface: GlassSurfaceView) {
        self.surface = surface
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    /// The touches the observer is forwarding now.
    public var liveTouchCount: Int {
        ids.count
    }

    private func id(for touch: UITouch) -> Int {
        let key = ObjectIdentifier(touch)
        if let id = ids[key] { return id }
        nextID += 1
        ids[key] = nextID
        return nextID
    }

    override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let surface else { return }
        for touch in touches {
            surface.beginTouch(id: id(for: touch), at: touch.location(in: surface))
        }
    }

    override public func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let surface else { return }
        for touch in touches {
            surface.moveTouch(id: id(for: touch), to: touch.location(in: surface))
        }
    }

    override public func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, cancelled: false)
    }

    override public func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        for touch in touches {
            guard let id = ids.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            if cancelled {
                surface?.cancelTouch(id: id)
            } else {
                surface?.endTouch(id: id)
            }
        }
        // The last touch is gone: this sequence never recognized, so it ends
        // as a failure, which releases anything waiting on it.
        if ids.isEmpty, state == .possible {
            state = .failed
        }
    }

    override public func reset() {
        // The system reset the recognizer: anything still live was cancelled.
        for id in ids.values {
            surface?.cancelTouch(id: id)
        }
        ids.removeAll()
    }

    // MARK: UIGestureRecognizerDelegate

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        true
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer
    ) -> Bool {
        false
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        false
    }
}
#endif
