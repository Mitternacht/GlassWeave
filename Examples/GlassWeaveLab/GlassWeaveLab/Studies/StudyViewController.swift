import GlassWeave
import GlassWeaveUIKit
import Metal
import UIKit

/// The base of the material studies (GW-29): one full-screen glass surface
/// with a procedural background, native controls above it, and a
/// deterministic script.
///
/// - **One surface, one producer.** The producer draws the study's background
///   into the surface's frames and returns `nil` while nothing about it has
///   changed (the surface then draws the same frame again; the GW-24 rule).
///   The pearl and the pill have still backgrounds, so after the first frame
///   they submit no background work at all.
/// - **A script, not a clock.** Every moving thing is a pure function of the
///   script time `t` (the surface's own effect clock is paused). Live, `t` is
///   the seconds since the screen appeared, ticked 30 times a second; with
///   `-lab.studyTime <seconds>` it is pinned, so a capture is repeatable; under
///   Reduce Motion it rests at the study's rest time and no tick runs.
/// - **Panels at placeholders.** The glass panels sit at the frames of clear
///   placeholder views laid out by Auto Layout beside the native controls, so
///   the layout mirrors in right-to-left and follows Dynamic Type.
/// - **Rule 10.** The screen checks that no two panels' quads overlap (the
///   panel grown by its halo and its grounding's reach) and reports it in the
///   diagnostics line (`-lab.studyDiagnostics YES` shows it).
///
/// Launch arguments: `-lab.study pearl|pill|shelf` opens a study as the
/// window's root, `-lab.studyTime <s>` pins the script, `-lab.studyTwin YES`
/// adds a real `UIGlassEffect` capsule on the same backdrop to compare with,
/// `-lab.studyDiagnostics YES` shows the diagnostics line.
class StudyViewController: UIViewController {
    // MARK: Subclass hooks

    /// The study.
    var kind: StudyKind { fatalError("Subclasses override `kind`.") }
    /// The appearance the study is designed for.
    var studyStyle: UIUserInterfaceStyle { .dark }
    /// The script time shown under Reduce Motion, in seconds.
    var restTime: Double { 0 }
    /// Whether the script time changes the picture; a study whose picture is
    /// still has no tick.
    var animates: Bool { true }
    /// Adds the native controls and the clear placeholders to `content`.
    func buildContent(in content: UIView) {}
    /// The glass panels at script time `time`, with frames in the surface's
    /// coordinates (see ``frame(of:)``).
    func panels(at time: Double) -> [GlassPanel] { [] }
    /// What the background shows at script time `time`.
    func backdropContent(at time: Double) -> (rects: [CGRect], time: Double, progress: Double) { ([], 0, 0) }
    /// Updates the native controls for script time `time` (labels).
    func applyScript(at time: Double) {}

    // MARK: Rendering

    private struct Rendering {
        let surface: GlassSurfaceView
        let renderer: StudyBackdropRenderer
    }

    private var rendering: Result<Rendering, any Error>?
    private var backdrop = StudyBackdrop()
    private var producedBackdrop: StudyBackdrop?
    private var requestedPanels: [GlassPanel] = []

    // MARK: Views and state

    /// Holds the native controls; it covers the surface.
    let content = UIView()
    private let closeButton = UIButton(configuration: .glass())
    private let diagnosticsLabel = UILabel()
    private var timer: Timer?
    private let startTime = CACurrentMediaTime()
    private(set) var scriptTime = 0.0
    private var quadsApart = true
    private var drawCount = 0

    private static var pinnedTime: Double? {
        UserDefaults.standard.object(forKey: "lab.studyTime") == nil ? nil : UserDefaults.standard.double(forKey: "lab.studyTime")
    }

    // MARK: Environment

    var isDark: Bool { traitCollection.userInterfaceStyle == .dark }
    var isRightToLeft: Bool { view.effectiveUserInterfaceLayoutDirection == .rightToLeft }

    var reduceMotion: Bool {
        if case let .success(rendering) = rendering { return rendering.surface.accessibilitySettings.reduceMotion }
        return UIAccessibility.isReduceMotionEnabled
    }

    var reduceTransparency: Bool {
        if case let .success(rendering) = rendering { return rendering.surface.accessibilitySettings.reduceTransparency }
        return UIAccessibility.isReduceTransparencyEnabled
    }

    var increasedContrast: Bool { traitCollection.accessibilityContrast == .high }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = studyStyle
        view.backgroundColor = studyStyle == .dark ? .black : .white
        if UserDefaults.standard.bool(forKey: "lab.increaseContrast") {
            traitOverrides.accessibilityContrast = .high
        }
        setUpRendering()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.backgroundColor = .clear
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        buildContent(in: content)
        addChrome()
        registerForTraitChanges([
            UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self, UITraitPreferredContentSizeCategory.self,
        ]) { (self: Self, _) in
            self.view.setNeedsLayout()
            self.refresh()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startTimerIfNeeded()
        refresh()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        studyStyle == .dark ? .lightContent : .darkContent
    }

    // MARK: Chrome: the close button, the twin, the diagnostics

    private func addChrome() {
        closeButton.configuration?.image = UIImage(systemName: "xmark")
        closeButton.accessibilityLabel = String(localized: "Close")
        closeButton.accessibilityIdentifier = "study.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = presentingViewController == nil
        content.addSubview(closeButton)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            closeButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        if UserDefaults.standard.bool(forKey: "lab.studyTwin") {
            addTwin(safe: safe)
        }
        if UserDefaults.standard.bool(forKey: "lab.studyDiagnostics") {
            diagnosticsLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
            diagnosticsLabel.numberOfLines = 0
            diagnosticsLabel.textColor = studyStyle == .dark ? UIColor(white: 1, alpha: 0.7) : UIColor(white: 0, alpha: 0.6)
            diagnosticsLabel.accessibilityIdentifier = "study.diagnostics"
            diagnosticsLabel.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(diagnosticsLabel)
            NSLayoutConstraint.activate([
                diagnosticsLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
                diagnosticsLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
                diagnosticsLabel.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -2),
            ])
        }
    }

    /// A real `UIGlassEffect` capsule on the same backdrop, to compare the
    /// study's glass with Apple's by eye.
    private func addTwin(safe: UILayoutGuide) {
        let native = NativeGlassView()
        native.cornerConfiguration = .capsule()
        native.accessibilityIdentifier = "study.twin"
        let label = UILabel()
        label.text = String(localized: "Apple glass, UIGlassEffect")
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        native.contentView.addSubview(label)
        native.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(native)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: native.contentView.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: native.contentView.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: native.contentView.topAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: native.contentView.bottomAnchor, constant: -18),
            native.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            native.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -28),
        ])
    }

    // MARK: Rendering setup

    private func setUpRendering() {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw StudyFailure.noMetalDevice }
            guard let queue = device.makeCommandQueue() else { throw StudyFailure.noCommandQueue }
            queue.label = "GlassWeaveLab study \(kind.rawValue)"
            let renderer = try StudyBackdropRenderer(device: device, kind: kind)
            let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
            surface.accessibilityIdentifier = "study.surface"
            if let override = LabViewController.accessibilitySettingsOverride {
                surface.accessibilitySettingsSource = .fixed(override)
            }
            // The script is the only clock: the surface's effect clock stays
            // still, and each moving thing is driven by the script time.
            surface.isEffectClockPaused = true
            surface.renderObserver = { [weak self] _ in
                self?.drawCount += 1
                self?.updateDiagnostics()
            }
            surface.visibilityHandler = { [weak self] visible in
                if !visible, case let .success(rendering) = self?.rendering { rendering.renderer.trim() }
                self?.updateDiagnostics()
            }
            surface.accessibilitySettingsHandler = { [weak self] _ in
                self?.startTimerIfNeeded()
                self?.refresh()
            }
            surface.setFrameProducer { [weak self] commandBuffer, pixelSize in
                self?.produceBackground(into: commandBuffer, pixelSize: pixelSize)
            }
            surface.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(surface)
            NSLayoutConstraint.activate([
                surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                surface.topAnchor.constraint(equalTo: view.topAnchor),
                surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            rendering = .success(Rendering(surface: surface, renderer: renderer))
        } catch {
            rendering = .failure(error)
        }
    }

    private enum StudyFailure: Error, CustomStringConvertible {
        case noMetalDevice
        case noCommandQueue

        var description: String {
            switch self {
            case .noMetalDevice: "No Metal device is available."
            case .noCommandQueue: "Could not create a command queue."
            }
        }
    }

    /// The background for the next draw, or `nil` when the frame on screen
    /// already shows it.
    private func produceBackground(into commandBuffer: any MTLCommandBuffer, pixelSize: (width: Int, height: Int)) -> BackgroundFrameLease? {
        guard case let .success(rendering) = rendering else { return nil }
        var next = backdrop
        next.pixelWidth = pixelSize.width
        next.pixelHeight = pixelSize.height
        if next == producedBackdrop, rendering.surface.renderer.currentFrame != nil {
            return nil
        }
        guard let lease = rendering.renderer.encodeFrame(into: commandBuffer, backdrop: next) else { return nil }
        producedBackdrop = next
        return lease
    }

    // MARK: Script

    private var currentTime: Double {
        if let pinned = Self.pinnedTime { return pinned }
        if reduceMotion { return restTime }
        return CACurrentMediaTime() - startTime
    }

    private var wantsTick: Bool {
        animates && Self.pinnedTime == nil && !reduceMotion && view.window != nil
    }

    private func startTimerIfNeeded() {
        guard isViewLoaded else { return }
        if wantsTick {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// The frame of `view`, in the surface's coordinates (the screen's, in
    /// points): where a panel for that placeholder goes.
    func frame(of view: UIView) -> CGRect {
        view.convert(view.bounds, to: self.view)
    }

    /// Recomputes the script's state: the labels, the panels and the
    /// background. Cheap; it sets panels and asks for a frame only when
    /// something changed.
    func refresh() {
        guard isViewLoaded, case let .success(rendering) = rendering, view.bounds.width > 0 else { return }
        let surface = rendering.surface
        let time = currentTime
        scriptTime = time
        applyScript(at: time)
        view.layoutIfNeeded()

        let list = panels(at: time)
        if list != requestedPanels {
            do {
                try surface.setPanels(list)
                requestedPanels = list
            } catch {
                self.rendering = .failure(error)
                return
            }
        }
        quadsApart = Self.quadsAreApart(list)

        let drawing = backdropContent(at: time)
        var next = StudyBackdrop()
        next.displayScale = Double(surface.traitCollection.displayScale)
        next.dark = isDark
        next.screenSize = view.bounds.size
        next.time = drawing.time
        next.progress = drawing.progress
        next.rects = drawing.rects
        if next != backdrop {
            backdrop = next
            surface.requestFrame()
        }
        updateDiagnostics()
    }

    // MARK: Rule 10

    /// The panel's quad as the renderer draws it, estimated from the public
    /// values: the outline's bounds grown by one point and the halo, and at
    /// least as far as the grounding's pre-pass reaches (the drop's offset,
    /// spread and three blur sigmas, or the contact line), plus a margin.
    static func quad(of panel: GlassPanel) -> CGRect {
        let parameters = panel.parameters
        var reach = 1 + (parameters.glow.hasHalo ? parameters.glow.haloRadius : 0)
        let grounding = parameters.grounding
        if grounding.isEnabled {
            let elevation = parameters.lighting.isEnabled ? parameters.lighting.key.elevation : grounding.lightElevation
            let longer = min(max(tan(50 * .pi / 180) / tan(max(elevation, 5) * .pi / 180), 0.35), 3)
            if grounding.drop.opacity > 0 {
                reach = max(reach, grounding.drop.offset * longer + max(grounding.drop.spread, 0) + 1.5 * grounding.drop.blur + 2)
            }
            if grounding.contact.opacity > 0, grounding.contact.width > 0 {
                reach = max(reach, 1.3 * grounding.contact.width + 2)
            }
        }
        return panel.shapeBounds.insetBy(dx: -reach, dy: -reach)
    }

    /// Whether no two panels' quads overlap.
    static func quadsAreApart(_ panels: [GlassPanel]) -> Bool {
        let quads = panels.map(quad(of:))
        for (index, quad) in quads.enumerated() {
            for other in quads[(index + 1)...] {
                let shared = quad.intersection(other)
                if !shared.isNull, shared.width > 0, shared.height > 0 { return false }
            }
        }
        return true
    }

    // MARK: Diagnostics

    private func updateDiagnostics() {
        guard isViewLoaded, diagnosticsLabel.superview != nil else { return }
        if case let .failure(error) = rendering {
            diagnosticsLabel.text = "\(kind.rawValue) | rendering failed: \(error)"
            return
        }
        let produced: Int
        if case let .success(rendering) = rendering { produced = rendering.renderer.producedCount } else { produced = 0 }
        diagnosticsLabel.text = String(
            format: "%@ | t=%.1f | panels %d | quads apart %@ | draws %d | backgrounds %d | RM %@ RT %@ IC %@",
            kind.rawValue, scriptTime, requestedPanels.count, quadsApart ? "yes" : "NO", drawCount, produced,
            reduceMotion ? "yes" : "no", reduceTransparency ? "yes" : "no", increasedContrast ? "yes" : "no"
        )
    }

    // MARK: Factory and menu

    static func make(_ kind: StudyKind) -> StudyViewController {
        switch kind {
        case .pearl: PearlStudyViewController()
        case .pill: PillStudyViewController()
        case .shelf: ShelfStudyViewController()
        }
    }

    /// The laboratory's "Studies" menu: one entry per study, each opening the
    /// study over the window.
    static func menuButton(presentedBy presenter: UIViewController, hidden: Bool) -> UIButton {
        let button = UIButton(configuration: .bordered())
        button.configuration?.title = String(localized: "Material studies")
        button.accessibilityIdentifier = "lab.openStudies"
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: StudyKind.allCases.map { kind in
            UIAction(title: kind.title, identifier: UIAction.Identifier("lab.study.\(kind.rawValue)")) { [weak presenter] _ in
                guard let presenter, presenter.presentedViewController == nil else { return }
                let study = make(kind)
                study.modalPresentationStyle = .fullScreen
                presenter.present(study, animated: true)
            }
        })
        button.isHidden = hidden
        return button
    }
}
