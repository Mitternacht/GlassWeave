#if canImport(UIKit)
import Dispatch
import Metal
import QuartzCore

/// Takes drawables from a Metal layer on a background queue, so the main
/// thread never waits for one.
///
/// `CAMetalLayer.nextDrawable()` blocks until a drawable is free or the
/// layer's one-second timeout passes. GlassWeave's surface used to call it
/// on the main thread (through `MTKView.currentRenderPassDescriptor`), so a
/// layer whose drawables were all held elsewhere froze the UI for a second.
/// The surface now asks this type for a drawable when a frame is pending and
/// can be drawn, keeps drawing on the main thread, and gets the drawable
/// back in a main-actor completion. A drawable that arrives late, or that is
/// no longer wanted, is simply released.
///
/// One request is outstanding at a time (the surface does not ask again
/// until the completion has run), and the call is documented as safe from
/// any thread, so the layer is touched here only through `nextDrawable()`.
///
/// Not `CAMetalDisplayLink`: the spike (`docs/decisions/metal-backend.md`)
/// found that a layer with a display link attached raises an Objective-C
/// exception on any other `nextDrawable()` call, which `MTKView` and the
/// laboratory's drawable stress both make.
final class DrawableAcquirer: @unchecked Sendable {
    /// A drawable (or `nil` after the layer's timeout) crossing from the
    /// acquiring queue to the main actor. It is only passed on, never used
    /// off the main actor.
    final class Acquired: @unchecked Sendable {
        let drawable: (any CAMetalDrawable)?
        init(_ drawable: (any CAMetalDrawable)?) { self.drawable = drawable }
    }

    private let layer: CAMetalLayer
    private let queue = DispatchQueue(label: "dev.glassweave.drawable-acquisition", qos: .userInteractive)

    init(layer: CAMetalLayer) {
        self.layer = layer
    }

    /// Calls `completion` on the main actor with the next drawable, or with
    /// `nil` when the layer timed out or has none to give.
    func acquire(_ completion: @escaping @MainActor @Sendable (Acquired) -> Void) {
        queue.async { [self] in
            let acquired = Acquired(layer.nextDrawable())
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(acquired) }
            }
        }
    }
}
#endif
