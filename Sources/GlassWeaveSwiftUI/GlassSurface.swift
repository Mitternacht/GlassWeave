#if canImport(UIKit)
import GlassWeave
import GlassWeaveUIKit
import Metal
import SwiftUI
import UIKit

/// A SwiftUI view that shows a GlassWeave glass surface (`GlassSurfaceView`).
///
/// Put it behind native SwiftUI controls, in a `ZStack`: the surface is
/// decorative. It is hidden from accessibility (SwiftUI's
/// `accessibilityHidden(_:)` here, and the UIKit host's own flags) and takes no
/// touches, so VoiceOver and gestures reach only the controls above it.
///
/// **What runs where.** The view's `body` only describes the surface. The UIKit
/// host is made once per identity, with its renderer, and every later SwiftUI
/// update goes through ``GlassSurfaceConfiguration``: the configuration is
/// applied in `updateUIView` only when it changed, and only the fields that
/// changed. The background and its frames come from the configuration's
/// ``GlassSurfaceContent``, whose producer runs inside the UIKit host's draw,
/// never in body evaluation. A slider that changes a panel's parameters
/// therefore creates no renderer, pipeline or texture: the one renderer lives
/// as long as the view's identity.
///
/// **Lifecycle.** Appearing, disappearing (a navigation push puts the surface's
/// window away), hiding, and the scene's state are handled by the UIKit host
/// as for any `GlassSurfaceView`; the adapter adds no rule of its own. A new
/// `.id` (or removing the view) tears the surface down and a new identity
/// makes one new surface with one new renderer.
///
/// The renderer needs a Metal command queue; the library never creates one.
/// Pass the app's queue, the one its frame producer's textures are made on.
///
/// macOS is not a presentation target: this type exists only where UIKit does.
///
/// > Important: Experimental. This API may change before a stable release.
public struct GlassSurface: View {
    private let commandQueue: any MTLCommandQueue
    private let configuration: GlassSurfaceConfiguration
    private let onFailure: (@MainActor (any Error) -> Void)?

    /// - Parameters:
    ///   - commandQueue: The queue the surface's renderer submits to.
    ///   - configuration: The surface's low-frequency configuration.
    ///   - onFailure: Called on the main actor, after the update that hit it,
    ///     with an error the surface could not recover from by itself: the
    ///     renderer could not be built (the surface then shows an opaque
    ///     fallback), `GlassParameterError` for a panel with a non-finite
    ///     value, or `BackgroundSourceError` for a source frame the renderer
    ///     rejected. The previous panels and source stay in the last two cases.
    public init(
        commandQueue: any MTLCommandQueue,
        configuration: GlassSurfaceConfiguration = GlassSurfaceConfiguration(),
        onFailure: (@MainActor (any Error) -> Void)? = nil
    ) {
        self.commandQueue = commandQueue
        self.configuration = configuration
        self.onFailure = onFailure
    }

    public var body: some View {
        HostedGlassSurface(commandQueue: commandQueue, configuration: configuration, onFailure: onFailure)
            .accessibilityHidden(true)
    }
}

/// The `UIViewRepresentable` behind ``GlassSurface``. Its coordinator owns the
/// surface and the renderer, so SwiftUI updates never recreate them.
struct HostedGlassSurface: UIViewRepresentable {
    let commandQueue: any MTLCommandQueue
    let configuration: GlassSurfaceConfiguration
    let onFailure: (@MainActor (any Error) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(commandQueue: commandQueue)
    }

    /// Called once per identity, so the renderer is built here and only here.
    func makeUIView(context: Context) -> UIView {
        context.coordinator.makeView(onFailure: onFailure)
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.update(configuration, onFailure: onFailure)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    /// The surface takes the space it is offered, like a plain `UIView`.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 100, height: 100))
    }

    @MainActor
    final class Coordinator {
        private let commandQueue: any MTLCommandQueue
        private(set) var surface: GlassSurfaceView?
        private var applied: GlassSurfaceConfiguration?
        private var failureHandler: (@MainActor (any Error) -> Void)?

        init(commandQueue: any MTLCommandQueue) {
            self.commandQueue = commandQueue
        }

        func makeView(onFailure: (@MainActor (any Error) -> Void)?) -> UIView {
            failureHandler = onFailure
            do {
                let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: commandQueue))
                self.surface = surface
                return surface
            } catch {
                report(error)
                // No renderer: the same opaque, decorative fill that a surface
                // without a source shows.
                let fallback = UIView()
                fallback.backgroundColor = .secondarySystemBackground
                fallback.isAccessibilityElement = false
                fallback.accessibilityElementsHidden = true
                fallback.isUserInteractionEnabled = false
                return fallback
            }
        }

        /// Applies what differs from the last applied configuration.
        func update(_ configuration: GlassSurfaceConfiguration, onFailure: (@MainActor (any Error) -> Void)?) {
            failureHandler = onFailure
            guard let surface, configuration != applied else { return }
            let previous = applied
            applied = configuration

            if previous?.content !== configuration.content {
                previous?.content?.detach(from: surface)
                do {
                    try configuration.content?.attach(to: surface)
                } catch {
                    report(error)
                }
            }
            if previous?.accessibilitySettings != configuration.accessibilitySettings {
                surface.accessibilitySettingsSource = configuration.accessibilitySettings
            }
            if previous?.qualityEnvironment != configuration.qualityEnvironment {
                surface.qualityEnvironmentSource = configuration.qualityEnvironment
            }
            if previous?.quality != configuration.quality {
                surface.quality = configuration.quality
            }
            if previous?.motionClass != configuration.motionClass {
                surface.motionClass = configuration.motionClass
            }
            if previous?.panels != configuration.panels {
                do {
                    try surface.setPanels(configuration.panels)
                } catch {
                    report(error)
                }
            }
        }

        /// Ends the surface's use of the content. The renderer goes with the
        /// surface when SwiftUI lets go of the view.
        func tearDown() {
            if let surface { applied?.content?.detach(from: surface) }
            applied = nil
        }

        /// Reports after the current update: the handler may change state, which
        /// SwiftUI does not allow in the middle of a view update.
        private func report(_ error: any Error) {
            guard let handler = failureHandler else { return }
            Task { @MainActor in handler(error) }
        }
    }
}
#endif
