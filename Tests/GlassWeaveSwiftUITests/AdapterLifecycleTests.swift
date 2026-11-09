#if canImport(UIKit)
import Metal
import Observation
import SwiftUI
import Testing
import UIKit
@testable import GlassWeave
@testable import GlassWeaveSwiftUI
@testable import GlassWeaveUIKit

/// What the SwiftUI screen below reads: a value that changes a panel (fifty
/// times), an identity, and a navigation path.
@MainActor
@Observable
private final class ScreenModel {
    var refraction = 0.1
    var generation = 0
    var path: [Int] = []
}

/// A screen like an app's: a surface behind a native button, and a pushed
/// screen with its own surface.
private struct ScreenUnderTest: View {
    let queue: any MTLCommandQueue
    @Bindable var model: ScreenModel

    private func configuration(refraction: Double) -> GlassSurfaceConfiguration {
        GlassSurfaceConfiguration(panels: [
            GlassPanel(
                frame: CGRect(x: 16, y: 16, width: 160, height: 100),
                parameters: GlassParameters(cornerRadius: 24, refraction: refraction)
            ),
        ])
    }

    var body: some View {
        NavigationStack(path: $model.path) {
            ZStack {
                GlassSurface(commandQueue: queue, configuration: configuration(refraction: model.refraction))
                    .id(model.generation)
                Button("Action") {}
            }
            .navigationDestination(for: Int.self) { _ in
                ZStack {
                    GlassSurface(commandQueue: queue, configuration: configuration(refraction: 0.5))
                    Text("Pushed")
                }
            }
        }
    }
}

/// GW-15: the SwiftUI adapter makes one renderer per view identity and nothing
/// more, however SwiftUI updates the view, and the surface stays decorative.
///
/// The process has no window scene, so the surface's visibility is not what
/// this checks; the count of renderers, which the renderer census keeps for
/// every GlassWeave renderer, and the accessibility flags are.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AdapterLifecycleTests {
    private static func surfaces(in view: UIView) -> [GlassSurfaceView] {
        var found: [GlassSurfaceView] = []
        if let surface = view as? GlassSurfaceView { found.append(surface) }
        for subview in view.subviews { found += surfaces(in: subview) }
        return found
    }

    /// Runs the main run loop, so SwiftUI updates, until `condition` holds.
    private static func wait(
        _ window: UIWindow, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation,
        until condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for: \(comment)", sourceLocation: sourceLocation)
                return
            }
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The surface and every view above it, up to the hosting view, are
    /// decorative: none is an accessibility element, the surface hides its own
    /// elements, and it takes no touches.
    private static func expectDecorative(_ surface: GlassSurfaceView?, below root: UIView, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let surface else {
            Issue.record("The surface is gone", sourceLocation: sourceLocation)
            return
        }
        #expect(!surface.isAccessibilityElement, sourceLocation: sourceLocation)
        #expect(surface.accessibilityElementsHidden, sourceLocation: sourceLocation)
        #expect(!surface.hostedMetalView.isAccessibilityElement, sourceLocation: sourceLocation)
        #expect(!surface.isUserInteractionEnabled, sourceLocation: sourceLocation)
        var ancestor = surface.superview
        while let view = ancestor, view !== root {
            #expect(!view.isAccessibilityElement, sourceLocation: sourceLocation)
            ancestor = view.superview
        }
    }

    @Test func `One renderer per identity across fifty updates, an identity change, a push and a pop`() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        let queue = try #require(device.makeCommandQueue())
        let model = ScreenModel()
        let hosting = UIHostingController(rootView: ScreenUnderTest(queue: queue, model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let createdBefore = RendererCensus.created
        let liveBefore = RendererCensus.live
        var created: Int { RendererCensus.created - createdBefore }
        var live: Int { RendererCensus.live - liveBefore }

        // The surfaces are held weakly, so the test never keeps a renderer alive.
        weak var first: GlassSurfaceView?
        weak var second: GlassSurfaceView?
        weak var pushed: GlassSurfaceView?

        // The first display makes one surface with one renderer.
        try await Self.wait(window, "the first surface") { !Self.surfaces(in: hosting.view).isEmpty }
        first = Self.surfaces(in: hosting.view).first
        #expect(Self.surfaces(in: hosting.view).count == 1)
        #expect(created == 1)
        Self.expectDecorative(first, below: hosting.view)

        // Fifty updates of a value the surface's panel depends on. Each one
        // reaches the UIKit host (the panel follows), and none makes a renderer.
        for step in 1...50 {
            let value = 0.1 + 0.016 * Double(step)
            model.refraction = value
            try await Self.wait(window, "update \(step) to reach the surface") {
                guard let applied = first?.panel?.parameters.refraction else { return false }
                return abs(applied - value) < 1e-9
            }
        }
        #expect(created == 1, "fifty updates made \(created) renderers")
        #expect(Self.surfaces(in: hosting.view).first === first, "the surface was replaced by an update")
        Self.expectDecorative(first, below: hosting.view)

        // A new identity tears the surface down and makes one new one.
        model.generation += 1
        try await Self.wait(window, "the new identity's surface") {
            let found = Self.surfaces(in: hosting.view)
            return found.count == 1 && found.first !== first
        }
        second = Self.surfaces(in: hosting.view).first
        #expect(created == 2, "an identity change made \(created - 1) renderers")
        try await Self.wait(window, "the first identity's renderer to be released") { live == 1 }
        #expect(live == 1, "the first identity's renderer is still alive")
        #expect(first == nil, "the first identity's surface is still alive")
        Self.expectDecorative(second, below: hosting.view)

        // A push makes the pushed screen's one surface, a pop releases it, and
        // neither touches the first screen's surface.
        model.path = [1]
        try await Self.wait(window, "the pushed screen's surface") { created == 3 }
        #expect(created == 3, "a push made \(created - 2) renderers")
        pushed = Self.surfaces(in: hosting.view).first { $0 !== second }
        Self.expectDecorative(pushed, below: hosting.view)
        model.path = []
        try await Self.wait(window, "the pushed screen's renderer to be released") { live == 1 }
        #expect(live == 1, "the pushed screen's renderer is still alive")
        #expect(pushed == nil, "the pushed screen's surface is still alive")
        #expect(created == 3, "a pop made \(created - 3) renderers")
        #expect(Self.surfaces(in: hosting.view).contains { $0 === second }, "the first screen's surface was replaced")
        Self.expectDecorative(second, below: hosting.view)
        #expect(abs((second?.panel?.parameters.refraction ?? -1) - model.refraction) < 1e-9)
    }
}
#endif
