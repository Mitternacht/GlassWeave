@_spi(Census) import GlassWeave
import GlassWeaveSwiftUI
import GlassWeaveUIKit
import Metal
import SwiftUI
import UIKit

/// The SwiftUI example (GW-15): a `GlassSurface` behind native SwiftUI
/// controls, hosted in a `UIHostingController`. `-lab.swiftui YES` opens it as
/// the window's root; the laboratory's menu opens it over the main screen.
///
/// The controls change low-frequency configuration: a slider (the lens
/// strength), a toggle (the light), a picker (the quality tier) and a button
/// that gives the surface a new identity. The census line shows how many
/// renderers this screen created and how many are alive: dragging the slider
/// leaves it at 1, and the button makes it 2 (the old identity's renderer is
/// released at once, so "alive" stays 1). A real `UIGlassEffect` (the
/// package's `NativeGlassView`) sits above the panel for comparison.
///
/// Launch arguments: `-lab.swiftui YES`; `-lab.studyTime <s>` pins the
/// pebbles' drift, as for the studies; `-lab.swiftui.strength <0...1>`,
/// `-lab.swiftui.light NO` and `-lab.swiftui.quality balanced|minimal` set the
/// controls, for captures.
enum SwiftUIExample {
    static var launchRequested: Bool {
        UserDefaults.standard.bool(forKey: "lab.swiftui")
    }

    /// The screen in a hosting controller. `-lab.appearance` is applied by the
    /// scene; the screen asks for the dark look its sky is designed for.
    static func makeViewController() -> UIViewController {
        let host = UIHostingController(rootView: SwiftUIExampleScreen())
        host.view.backgroundColor = .black
        return host
    }

    /// The laboratory's menu entry, which opens the screen over the window.
    static func menuButton(presentedBy presenter: UIViewController, hidden: Bool) -> UIButton {
        let button = UIButton(configuration: .bordered())
        button.configuration?.title = String(localized: "GlassSurface in SwiftUI")
        button.accessibilityIdentifier = "lab.openSwiftUI"
        button.isHidden = hidden
        button.addAction(UIAction { [weak presenter] _ in
            guard let presenter, presenter.presentedViewController == nil else { return }
            presenter.present(
                LabPageHostViewController(page: makeViewController(), closeIdentifier: "swiftui.close"),
                animated: true
            )
        }, for: .primaryActionTriggered)
        return button
    }
}

// MARK: Background

/// The example's background: the shelf study's sky and pebbles, drawn by the
/// laboratory's own renderer inside the surface's draw. The pebbles drift a few
/// points over 48 seconds; a 10 Hz clock asks for a new frame, and the producer
/// answers `nil` while nothing changed, so a slider drag redraws the glass and
/// not the sky.
final class PebbleSky {
    let queue: any MTLCommandQueue
    private let renderer: StudyBackdropRenderer
    private let start = CACurrentMediaTime()
    private var time = 0.0
    private var produced: StudyBackdrop?

    /// The screen's size in points, set by the SwiftUI screen's layout.
    var screenSize = CGSize.zero {
        didSet { if oldValue != screenSize { content.requestFrame() } }
    }

    /// What the surface is given. Made once, so SwiftUI updates see no change.
    private(set) lazy var content = GlassSurfaceContent { [weak self] commandBuffer, pixelSize in
        self?.produce(into: commandBuffer, pixelSize: pixelSize)
    }

    private static var pinnedTime: Double? {
        UserDefaults.standard.object(forKey: "lab.studyTime") == nil ? nil : UserDefaults.standard.double(forKey: "lab.studyTime")
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let renderer = try? StudyBackdropRenderer(device: device, kind: .shelf)
        else { return nil }
        queue.label = "GlassWeaveLab SwiftUI example"
        self.queue = queue
        self.renderer = renderer
        if let pinned = Self.pinnedTime { time = pinned }
    }

    /// The 10 Hz clock: moves the pebbles unless motion is stilled.
    func tick() {
        guard Self.pinnedTime == nil else { return }
        let stilled = LabViewController.accessibilitySettingsOverride?.reduceMotion ?? UIAccessibility.isReduceMotionEnabled
        // Whole hundredths of a second, so equal times give equal pictures.
        let next = stilled ? 0 : ((CACurrentMediaTime() - start) * 100).rounded() / 100
        guard next != time else { return }
        time = next
        content.requestFrame()
    }

    private func produce(into commandBuffer: any MTLCommandBuffer, pixelSize: (width: Int, height: Int)) -> BackgroundFrameLease? {
        guard screenSize.width > 0 else { return nil }
        var next = StudyBackdrop()
        next.pixelWidth = pixelSize.width
        next.pixelHeight = pixelSize.height
        next.displayScale = Double(pixelSize.width) / Double(screenSize.width)
        next.screenSize = screenSize
        next.time = time
        if next == produced, content.surface?.renderer.currentFrame != nil { return nil }
        guard let lease = renderer.encodeFrame(into: commandBuffer, backdrop: next) else { return nil }
        produced = next
        return lease
    }
}

// MARK: Model

@Observable
final class SwiftUIExampleModel {
    /// Counts the changes a person made, to compare with the renderer count.
    private(set) var updates = 0

    var strength = SwiftUIExampleModel.launchValue("lab.swiftui.strength", 0.6) { didSet { updates += 1 } }
    var lightOn = UserDefaults.standard.object(forKey: "lab.swiftui.light") == nil || UserDefaults.standard.bool(forKey: "lab.swiftui.light") {
        didSet { updates += 1 }
    }
    var quality = SwiftUIExampleModel.launchQuality() { didSet { updates += 1 } }

    /// The surface's identity: the button changes it.
    var generation = 0

    private static func launchQuality() -> GlassQuality {
        switch UserDefaults.standard.string(forKey: "lab.swiftui.quality") {
        case "balanced": .balanced
        case "minimal": .minimal
        default: .full
        }
    }

    private static func launchValue(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : min(max(UserDefaults.standard.double(forKey: key), 0), 1)
    }
}

// MARK: Screen

struct SwiftUIExampleScreen: View {
    private struct CensusBaseline {
        var created = GlassRendererCensus.created
        var live = GlassRendererCensus.live
    }

    private static let cornerRadius = 40.0

    @State private var sky = PebbleSky()
    @State private var model = SwiftUIExampleModel()
    @State private var baseline = CensusBaseline()
    /// The surface's and the card's frames in the screen's coordinates.
    @State private var stage = CGRect.zero
    @State private var card = CGRect.zero
    @State private var failure: String?

    var body: some View {
        ZStack {
            if let sky {
                GlassSurface(commandQueue: sky.queue, configuration: configuration(sky: sky)) { error in
                    failure = String(describing: error)
                }
                .id(model.generation)
                // Measured inside `ignoresSafeArea`, so it is the whole screen.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    stage = frame
                    sky.screenSize = frame.size
                }
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
            VStack(spacing: 16) {
                Spacer(minLength: 0)
                twin
                controls
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                sky?.tick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: Configuration

    /// Everything the surface is told, from the model: it changes when a
    /// control changes, never per frame.
    private func configuration(sky: PebbleSky) -> GlassSurfaceConfiguration {
        var panels: [GlassPanel] = []
        if !card.isEmpty {
            let frame = card.offsetBy(dx: -stage.minX, dy: -stage.minY)
            panels = [GlassPanel(frame: frame, parameters: Self.parameters(strength: model.strength, lightOn: model.lightOn, frame: frame))]
        }
        return GlassSurfaceConfiguration(
            panels: panels,
            quality: model.quality,
            accessibilitySettings: LabViewController.accessibilitySettingsOverride.map { GlassSurfaceView.AccessibilitySettingsSource.fixed($0) } ?? .system,
            content: sky.content
        )
    }

    /// A refined, enhanced lens panel (the lab's shared look), a little
    /// thicker as the strength grows, over an even frost that keeps the white
    /// controls legible.
    private static func parameters(strength: Double, lightOn: Bool, frame: CGRect) -> GlassParameters {
        var parameters = RefinedLook.enhancedLens(
            corner: cornerRadius, bezel: 22, thickness: 8 + 26 * strength, dispersion: 0.15 + 0.45 * strength, dark: false
        )
        parameters.tint = GlassTint(red: 0.86, green: 0.92, blue: 1.0, strength: 0.10)
        parameters.lighting.fresnel = 0.8
        parameters.lighting.specular = 0.66
        parameters.lighting.isEnabled = lightOn
        parameters.edgeHighlight = lightOn ? 0 : 0.3
        parameters.frost = GlassFrost(
            profile: .clearRim, sigma: 6, transition: 36, grain: 0.05, thickness: 0.3, saturation: 1.05, brightness: 1.02
        ).legibility(text: .white, contrast: 2.4, rect: frame.insetBy(dx: 12, dy: 12), feather: 44)
        return parameters
    }

    // MARK: Foreground

    /// Apple's own glass, in the same shape, for comparison.
    private var twin: some View {
        AppleGlassTwin(cornerRadius: Self.cornerRadius)
            .frame(height: 68)
            .overlay {
                Text("Apple glass, UIGlassEffect")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GlassSurface in SwiftUI")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lens strength").font(.subheadline)
                Slider(value: $model.strength, in: 0...1)
                    .accessibilityIdentifier("swiftui.strength")
            }
            Toggle("Light", isOn: $model.lightOn)
                .accessibilityIdentifier("swiftui.light")
            Picker("Quality", selection: $model.quality) {
                Text("Full").tag(GlassQuality.full)
                Text("Balanced").tag(GlassQuality.balanced)
                Text("Minimal").tag(GlassQuality.minimal)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("swiftui.quality")
            Button("Rebuild surface") { model.generation += 1 }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("swiftui.rebuild")
            census
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { card = $0 }
    }

    /// The renderer census: how many renderers this screen created and how
    /// many are alive. Refreshed four times a second.
    private var census: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let created = GlassRendererCensus.created - baseline.created
            let live = GlassRendererCensus.live - baseline.live
            Text(failure ?? "Updates \(model.updates)  \u{00B7}  renderers created \(created)  \u{00B7}  alive \(live)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityIdentifier("swiftui.census")
        }
    }
}

// MARK: Comparison

/// Apple's glass (`NativeGlassView`, a `UIGlassEffect`) with one fixed corner
/// radius, to put beside the surface's panel.
private struct AppleGlassTwin: UIViewRepresentable {
    let cornerRadius: Double

    func makeUIView(context: Context) -> NativeGlassView {
        let view = NativeGlassView()
        view.cornerConfiguration = .corners(radius: .fixed(cornerRadius))
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: NativeGlassView, context: Context) {}
}
