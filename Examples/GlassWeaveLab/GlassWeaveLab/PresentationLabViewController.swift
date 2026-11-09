import GlassWeave
import GlassWeaveUIKit
import Metal
import QuartzCore
import UIKit

/// GW-27's presentation screen, opened with `-lab.presentation YES`.
///
/// One full-screen `GlassSurfaceView` with a still source and one panel with
/// an animated interior, a report of what the presentation path does, and
/// the pacing and quality controls: a tier switcher, a power and thermal
/// environment switcher (fixed values through the surface's injectable
/// source), and an interaction toggle.
///
/// The stress button takes every drawable the display does not show from
/// the surface's Metal layer on a background thread and keeps them, then
/// asks for a frame at once, so none is free. A main-actor heartbeat measures
/// how late the main thread wakes up meanwhile. Before GW-27 the host waited
/// for a drawable on the main thread (up to the layer's one-second timeout)
/// and the heartbeat showed about a second; the UI test `PresentationUITests`
/// fails on that code. `-lab.presentation.auto YES` runs the stress without a
/// tester, for captures.
final class PresentationLabViewController: UIViewController {
    private let surface: GlassSurfaceView?
    private let pattern: PatternSource?
    private var failure: String?

    // Heartbeat: a main-actor task that wakes every `interval` and records
    // how late each wake-up was.
    private let heartbeatInterval = Duration.milliseconds(10)
    private var heartbeat: Task<Void, Never>?
    private var worstLateness: Duration = .zero
    private var beats = 0

    // Drawable stress.
    private var heldDrawables: [DrawableBox] = []
    private var isHolding = false
    /// How long each `nextDrawable()` call of the last hold took, in ms.
    private var acquireDetail = ""

    private let heartbeatLabel = UILabel()
    private let heldLabel = UILabel()
    private let framesLabel = UILabel()
    private let pacingLabel = UILabel()
    private let qualityControl = UISegmentedControl(items: ["minimal", "balanced", "full"])
    private let environmentControl = UISegmentedControl(items: ["nominal", "low power", "serious", "critical"])
    private var requests = 0
    private var requestStart: ContinuousClock.Instant?
    private var drawLatencyMs = -1.0

    /// A drawable crossing from the acquiring thread to the main thread.
    /// It is only retained, never touched, until it is released.
    private nonisolated final class DrawableBox: @unchecked Sendable {
        let drawable: any CAMetalDrawable
        nonisolated init(_ drawable: any CAMetalDrawable) { self.drawable = drawable }
    }

    init() {
        var surface: GlassSurfaceView?
        var pattern: PatternSource?
        var failure: String?
        if let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() {
            queue.label = "GlassWeaveLab presentation"
            do {
                surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
                pattern = PatternSource(queue: queue)
            } catch {
                failure = String(describing: error)
            }
        } else {
            failure = "No Metal device is available."
        }
        self.surface = surface
        self.pattern = pattern
        self.failure = failure
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        guard let surface, let pattern else {
            let label = UILabel()
            label.text = failure
            label.numberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
                label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            ])
            return
        }
        surface.accessibilityIdentifier = "presentation.surface"
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)

        let hold = Self.button("Hold and request", id: "presentation.stress") { [weak self] in self?.holdDrawables(thenRequest: true) }
        let release = Self.button("Release drawables", id: "presentation.release") { [weak self] in self?.releaseDrawables() }
        let interaction = Self.button("Begin interaction", id: "presentation.interaction") { }
        interaction.addAction(UIAction { [weak self, weak interaction] _ in
            guard let self, let interaction, let surface = self.surface else { return }
            if surface.isInteracting {
                surface.endInteraction()
            } else {
                surface.beginInteraction()
            }
            interaction.configuration?.title = surface.isInteracting ? "End interaction" : "Begin interaction"
            self.updatePacing()
        }, for: .primaryActionTriggered)
        for (label, id) in [(heartbeatLabel, "presentation.heartbeat"), (heldLabel, "presentation.held"), (framesLabel, "presentation.frames"), (pacingLabel, "presentation.pacing")] {
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.numberOfLines = 0
            label.accessibilityIdentifier = id
        }
        qualityControl.selectedSegmentIndex = 2
        qualityControl.accessibilityIdentifier = "presentation.quality"
        qualityControl.addAction(UIAction { [weak self] _ in
            guard let self, let surface = self.surface else { return }
            surface.quality = [GlassQuality.minimal, .balanced, .full][self.qualityControl.selectedSegmentIndex]
            self.updatePacing()
        }, for: .valueChanged)
        environmentControl.selectedSegmentIndex = 0
        environmentControl.accessibilityIdentifier = "presentation.environment"
        environmentControl.addAction(UIAction { [weak self] _ in
            guard let self, let surface = self.surface else { return }
            let environments: [GlassQualityEnvironment] = [
                .nominal,
                GlassQualityEnvironment(isLowPowerModeEnabled: true),
                GlassQualityEnvironment(thermalState: .serious),
                GlassQualityEnvironment(thermalState: .critical),
            ]
            surface.qualityEnvironmentSource = .fixed(environments[self.environmentControl.selectedSegmentIndex])
            self.updatePacing()
        }, for: .valueChanged)
        let buttons = UIStackView(arrangedSubviews: [hold, release, interaction])
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 8
        let controls = UIStackView(arrangedSubviews: [buttons, qualityControl, environmentControl, pacingLabel, heartbeatLabel, heldLabel, framesLabel])
        controls.axis = .vertical
        controls.spacing = 6
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -8),
            controls.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            controls.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -8),
        ])

        surface.renderObserver = { [weak self] _ in
            guard let self else { return }
            if let start = requestStart {
                let parts = (ContinuousClock.now - start).components
                drawLatencyMs = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
                requestStart = nil
            }
            updateFrames()
        }
        do {
            let lease = try pattern.makeFrame(frameID: 1) { _ in }
            try surface.setSource(lease)
            lease.retire()
        } catch {
            heartbeatLabel.text = "Source failed: \(error)"
        }
        applyLaunchArguments(to: surface)
        updateFrames()
        updateHeld()
        updatePacing()
        startHeartbeat()
        if UserDefaults.standard.bool(forKey: "lab.presentation.auto") {
            Task { @MainActor [weak self] in await self?.runStressScript() }
        }
    }

    /// `-lab.presentation.quality minimal|balanced|full`,
    /// `-lab.presentation.environment lowpower|serious|critical` and
    /// `-lab.presentation.interact YES` start the screen in that state, for
    /// captures.
    private func applyLaunchArguments(to surface: GlassSurfaceView) {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "lab.presentation.quality") {
        case "minimal": qualityControl.selectedSegmentIndex = 0; surface.quality = .minimal
        case "balanced": qualityControl.selectedSegmentIndex = 1; surface.quality = .balanced
        default: break
        }
        switch defaults.string(forKey: "lab.presentation.environment") {
        case "lowpower":
            environmentControl.selectedSegmentIndex = 1
            surface.qualityEnvironmentSource = .fixed(GlassQualityEnvironment(isLowPowerModeEnabled: true))
        case "serious":
            environmentControl.selectedSegmentIndex = 2
            surface.qualityEnvironmentSource = .fixed(GlassQualityEnvironment(thermalState: .serious))
        case "critical":
            environmentControl.selectedSegmentIndex = 3
            surface.qualityEnvironmentSource = .fixed(GlassQualityEnvironment(thermalState: .critical))
        default: break
        }
        if defaults.bool(forKey: "lab.presentation.interact") { surface.beginInteraction() }
    }

    /// `-lab.presentation.auto YES`: the stress sequence without a tester,
    /// for captures and for reading the numbers on screen.
    private func runStressScript() async {
        try? await Task.sleep(for: .seconds(1.5))
        holdDrawables(thenRequest: true)
        try? await Task.sleep(for: .seconds(3.5))
        updateHeartbeat()
        updateFrames()
        releaseDrawables()
        try? await Task.sleep(for: .seconds(1))
        updateFrames()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let surface else { return }
        let bounds = surface.bounds
        guard bounds.width > 0 else { return }
        let size = CGSize(width: min(280, bounds.width - 40), height: 150)
        let frame = CGRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height
        )
        var parameters = GlassParameters(
            cornerRadius: 30, bezelWidth: 22, refraction: 0.85, edgeHighlight: 0.6,
            tint: GlassTint(red: 0.97, green: 0.98, blue: 1.0, strength: 0.3)
        )
        var interior = LabInterior.energy.interior(for: traitCollection)
        interior.speed = 2
        parameters.interior = interior
        try? surface.setPanel(GlassPanel(frame: frame, parameters: parameters))
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                guard let interval = self?.heartbeatInterval else { return }
                let due = clock.now + interval
                try? await Task.sleep(until: due, clock: clock)
                guard let self else { return }
                let lateness = clock.now - due
                if lateness > worstLateness { worstLateness = lateness }
                beats += 1
                if beats % 25 == 0 {
                    updateHeartbeat()
                    updatePacing()
                    // Completions do not refresh the report themselves.
                    updateFrames()
                }
            }
        }
    }

    private func resetHeartbeat() {
        worstLateness = .zero
        beats = 0
        updateHeartbeat()
    }

    private func updateHeartbeat() {
        let parts = worstLateness.components
        let milliseconds = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
        heartbeatLabel.text = String(format: "worstMs=%.1f beats=%d", milliseconds, beats)
    }

    // MARK: Drawable stress

    /// Finds the surface's Metal layer without a package API: the host's
    /// layer is the only `CAMetalLayer` in the surface's layer tree.
    private func metalLayer(in layer: CALayer) -> CAMetalLayer? {
        if let metal = layer as? CAMetalLayer { return metal }
        for sublayer in layer.sublayers ?? [] {
            if let found = metalLayer(in: sublayer) { return found }
        }
        return nil
    }

    /// Takes every drawable the layer has free, on a background thread (the
    /// call waits up to the layer's timeout once none is left), and keeps
    /// them until ``releaseDrawables()``.
    private func holdDrawables(thenRequest: Bool = false) {
        guard let surface, !isHolding, let layer = metalLayer(in: surface.layer) else { return }
        isHolding = true
        updateHeld()
        nonisolated(unsafe) let metal = layer
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var boxes: [DrawableBox] = []
            var detail: [String] = []
            for _ in 0..<max(metal.maximumDrawableCount - 1, 1) {
                let start = ContinuousClock.now
                let drawable = metal.nextDrawable()
                let elapsed = ContinuousClock.now - start
                let parts = elapsed.components
                detail.append(String(format: "%.0f", Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15))
                guard let drawable else { continue }
                boxes.append(DrawableBox(drawable))
            }
            let acquired = boxes
            let acquireDetail = detail.joined(separator: "/")
            DispatchQueue.main.async {
                guard let self else { return }
                self.heldDrawables = acquired
                self.acquireDetail = acquireDetail
                self.isHolding = false
                self.updateHeld()
                if thenRequest {
                    // At once, while the display still shows the drawable
                    // that the held ones leave over: nothing is free.
                    self.resetHeartbeat()
                    self.requestFrame()
                }
            }
        }
    }

    private func releaseDrawables() {
        heldDrawables.removeAll()
        updateHeld()
    }

    private func updatePacing() {
        guard let surface else { return }
        func rate(_ range: GlassFrameRate) -> String { String(format: "%.0f/%.0f/%.0f", range.minimum, range.preferred, range.maximum) }
        pacingLabel.text = "quality=\(surface.quality) effective=\(surface.effectiveQuality) class=\(surface.activeMotionClass) rate=\(rate(surface.effectFrameRate)) animating=\(surface.isAnimating ? 1 : 0) interacting=\(surface.isInteracting ? 1 : 0) timeouts=\(surface.drawableTimeouts)"
    }

    private func updateHeld() {
        heldLabel.text = "held=\(heldDrawables.count) holding=\(isHolding ? 1 : 0) acquireMs=\(acquireDetail.isEmpty ? "-" : acquireDetail)"
    }

    // MARK: Frames

    private func requestFrame() {
        requests += 1
        requestStart = .now
        surface?.requestFrame()
        updateFrames()
    }

    private func updateFrames() {
        guard let surface else { return }
        let statistics = surface.frameStatistics
        let outcome: String = switch surface.lastRenderOutcome {
        case .submitted: "submitted"
        case let .skipped(reason): "skipped(\(reason))"
        case nil: "none"
        }
        framesLabel.text = "submitted=\(statistics.submitted) requested=\(statistics.requested) inflight=\(statistics.framesInFlight) skipped=\(statistics.skipped) outcome=\(outcome) visible=\(surface.isVisible ? 1 : 0) drawLatencyMs=\(String(format: "%.0f", drawLatencyMs))"
    }

    private static func button(_ title: String, id: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.bordered()
        configuration.title = title
        configuration.titleLineBreakMode = .byWordWrapping
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = id
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        return button
    }
}
