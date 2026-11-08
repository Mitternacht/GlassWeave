import GlassWeave
import GlassWeaveUIKit
import Metal
import UIKit

/// The single comparison screen.
///
/// A stage shows one app-owned background through a `GlassSurfaceView`, with
/// one custom GlassWeave panel drawn over it. Native UIKit content sits above
/// the surface: the custom panel's text and button, and beside the panel a
/// genuine native-glass reference control. Below (portrait) or beside
/// (landscape) the stage are the comparison controls and diagnostics.
///
/// The background is the moving procedural source (``ProceduralBackground``)
/// driven by one ``DeterministicClock``. Launching with
/// `-lab.source pattern` presents the still four-corner orientation pattern
/// instead, for orientation checks.
final class LabViewController: UIViewController {
    enum SourceMode {
        case moving
        case pattern

        /// From the `lab.source` launch argument (`-lab.source pattern`).
        static var fromLaunchArguments: SourceMode {
            UserDefaults.standard.string(forKey: "lab.source") == "pattern" ? .pattern : .moving
        }
    }

    /// Counts reset presses so UI tests can confirm the action ran.
    private(set) var resetCount = 0
    private let mode = SourceMode.fromLaunchArguments

    // MARK: Stage

    private let stage = StageView()
    private let content = UIStackView()
    /// Holds the custom panel's native content. Its frame, converted into
    /// the surface's points, is the glass panel's frame.
    private let customPanel = UIView()
    private let customTitle = UILabel()
    private let customButton = UIButton(configuration: .borderedProminent())
    private var customTapCount = 0

    /// Native mode: genuine Apple glass around a real button. Nothing here
    /// creates a GlassWeave renderer; the glass samples whatever the system
    /// composites behind it, which here is the same stage.
    private let nativeGlass = NativeGlassView()
    private let nativeButton = UIButton(configuration: .plain())
    private let referenceCaption = UILabel()
    private var nativeTapCount = 0

    // MARK: Controls

    private let controls = UIScrollView()
    private let tintControl = UISegmentedControl(items: NativeTint.allCases.map(\.title))
    private let enabledSwitch = UISwitch()
    private let pauseButton = UIButton(configuration: .bordered())
    private let overlaySwitch = UISwitch()
    private let stageSwitch = UISwitch()
    private let newWindowButton = UIButton(configuration: .bordered())
    private let closeWindowButton = UIButton(configuration: .bordered())
    private let diagnosticsLabel = UILabel()
    private let resetButton = UIButton(configuration: .bordered())
    private var portraitConstraints: [NSLayoutConstraint] = []
    private var landscapeConstraints: [NSLayoutConstraint] = []

    // MARK: Rendering state

    private struct CustomStage {
        let surface: GlassSurfaceView
        let background: ProceduralBackground
        let pattern: PatternSource
    }

    private var custom: Result<CustomStage, any Error>?
    private var clock = DeterministicClock()
    /// Whether the user wants motion; Reduce Motion also stops it.
    private var wantsMotion = true
    private var showsFrameID = true
    private var updateLink: UIUpdateLink?
    private var nextFrameID: UInt64 = 1
    private var lastRelease: BackgroundFrameRelease?
    /// The frame-ID strip's center, in the surface's points.
    private var stripCenterY: CGFloat = 0
    /// Submissions counted when the surface last stopped being visible, and
    /// how many it made while hidden (always zero when scheduling works).
    private var submittedWhenHidden: Int?
    private var hiddenPeriodSubmissions: Int?

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setUpStage()
        setUpControls()
        setUpLayout()
        setUpCustomRendering()
        setUpClock()
        reset()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.updateCustomPanel()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(reduceMotionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil
        )
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Controls below the stage when taller than wide, beside it otherwise,
        // decided from local bounds.
        let landscape = view.bounds.width > view.bounds.height
        if landscape, landscapeConstraints.first?.isActive != true {
            NSLayoutConstraint.deactivate(portraitConstraints)
            NSLayoutConstraint.activate(landscapeConstraints)
        } else if !landscape, portraitConstraints.first?.isActive != true {
            NSLayoutConstraint.deactivate(landscapeConstraints)
            NSLayoutConstraint.activate(portraitConstraints)
        }
    }

    /// Returns every laboratory control to its initial state.
    func reset() {
        resetCount += 1
        resetNativeReference()
        customTapCount = 0
        clock.reset()
        wantsMotion = true
        showsFrameID = true
        overlaySwitch.isOn = true
        stageSwitch.isOn = true
        applyStageVisibility()
        applyMotionState()
        if mode == .pattern {
            presentNextPatternFrame()
        } else if case let .success(stage) = custom {
            stage.surface.requestFrame()
        }
        updateDiagnostics()
    }

    // MARK: Stage setup

    private func setUpStage() {
        stage.accessibilityIdentifier = "lab.stage"
        stage.clipsToBounds = true
        stage.backgroundColor = .secondarySystemBackground
        stage.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stage)

        customTitle.text = String(localized: "Custom GlassWeave")
        customTitle.font = .preferredFont(forTextStyle: .headline)
        customTitle.adjustsFontForContentSizeCategory = true
        customTitle.textAlignment = .center
        customTitle.numberOfLines = 0

        customButton.configuration?.title = String(localized: "Custom action")
        customButton.accessibilityIdentifier = "lab.customButton"
        customButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            customTapCount += 1
            updateDiagnostics()
        }, for: .primaryActionTriggered)

        let panelContent = UIStackView(arrangedSubviews: [customTitle, customButton])
        panelContent.axis = .vertical
        panelContent.alignment = .center
        panelContent.spacing = 10
        panelContent.translatesAutoresizingMaskIntoConstraints = false
        customPanel.addSubview(panelContent)
        customPanel.accessibilityIdentifier = "lab.customPanel"
        customPanel.translatesAutoresizingMaskIntoConstraints = false

        nativeButton.configuration?.title = String(localized: "Native action")
        nativeButton.configuration?.baseForegroundColor = .label
        nativeButton.accessibilityIdentifier = "lab.nativeButton"
        nativeButton.translatesAutoresizingMaskIntoConstraints = false
        nativeButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            nativeTapCount += 1
            updateDiagnostics()
        }, for: .primaryActionTriggered)
        nativeGlass.cornerConfiguration = .capsule()
        nativeGlass.accessibilityIdentifier = "lab.nativeGlass"
        nativeGlass.contentView.addSubview(nativeButton)

        referenceCaption.text = String(localized: "Native reference")
        referenceCaption.font = .preferredFont(forTextStyle: .footnote)
        referenceCaption.adjustsFontForContentSizeCategory = true
        referenceCaption.textColor = .label
        referenceCaption.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.75)
        referenceCaption.layer.cornerRadius = 6
        referenceCaption.layer.masksToBounds = true

        let reference = UIStackView(arrangedSubviews: [referenceCaption, nativeGlass])
        reference.axis = .vertical
        reference.alignment = .center
        reference.spacing = 6

        content.addArrangedSubview(customPanel)
        content.addArrangedSubview(reference)
        content.axis = .vertical
        content.alignment = .center
        content.spacing = 20
        content.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(content)

        let safe = stage.safeAreaLayoutGuide
        // Nominal 320 x 180 points, narrower when the stage is.
        let preferredWidth = customPanel.widthAnchor.constraint(equalToConstant: 320)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 16),
            content.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: 8),
            preferredWidth,
            customPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            panelContent.centerXAnchor.constraint(equalTo: customPanel.centerXAnchor),
            panelContent.centerYAnchor.constraint(equalTo: customPanel.centerYAnchor, constant: -14),
            panelContent.leadingAnchor.constraint(greaterThanOrEqualTo: customPanel.leadingAnchor, constant: 24),
            panelContent.topAnchor.constraint(greaterThanOrEqualTo: customPanel.topAnchor, constant: 20),
            panelContent.bottomAnchor.constraint(lessThanOrEqualTo: customPanel.bottomAnchor, constant: -48),
            nativeButton.leadingAnchor.constraint(equalTo: nativeGlass.contentView.leadingAnchor, constant: 20),
            nativeButton.trailingAnchor.constraint(equalTo: nativeGlass.contentView.trailingAnchor, constant: -20),
            nativeButton.topAnchor.constraint(equalTo: nativeGlass.contentView.topAnchor, constant: 8),
            nativeButton.bottomAnchor.constraint(equalTo: nativeGlass.contentView.bottomAnchor, constant: -8),
        ])
        stage.onLayout = { [weak self] in self?.updateCustomPanel() }
    }

    // MARK: Controls setup

    private func setUpControls() {
        tintControl.accessibilityIdentifier = "lab.nativeTint"
        tintControl.addAction(UIAction { [weak self] _ in self?.applyNativeState() }, for: .valueChanged)
        enabledSwitch.accessibilityIdentifier = "lab.nativeEnabled"
        enabledSwitch.accessibilityLabel = String(localized: "Native action enabled")
        enabledSwitch.addAction(UIAction { [weak self] _ in self?.applyNativeState() }, for: .valueChanged)

        pauseButton.accessibilityIdentifier = "lab.pause"
        pauseButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            wantsMotion.toggle()
            applyMotionState()
            updateDiagnostics()
        }, for: .primaryActionTriggered)
        overlaySwitch.accessibilityIdentifier = "lab.frameIDOverlay"
        overlaySwitch.accessibilityLabel = String(localized: "Frame ID overlay")
        overlaySwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            showsFrameID = overlaySwitch.isOn
            if case let .success(stage) = custom { stage.surface.requestFrame() }
            updateDiagnostics()
        }, for: .valueChanged)

        stageSwitch.accessibilityIdentifier = "lab.stageVisible"
        stageSwitch.accessibilityLabel = String(localized: "Show stage")
        stageSwitch.addAction(UIAction { [weak self] _ in self?.applyStageVisibility() }, for: .valueChanged)

        newWindowButton.configuration?.title = String(localized: "New window")
        newWindowButton.accessibilityIdentifier = "lab.newWindow"
        newWindowButton.addAction(UIAction { [weak self] _ in self?.openNewWindow() }, for: .primaryActionTriggered)
        closeWindowButton.configuration?.title = String(localized: "Close window")
        closeWindowButton.accessibilityIdentifier = "lab.closeWindow"
        closeWindowButton.addAction(UIAction { [weak self] _ in self?.closeWindow() }, for: .primaryActionTriggered)

        diagnosticsLabel.font = .preferredFont(forTextStyle: .footnote)
        diagnosticsLabel.adjustsFontForContentSizeCategory = true
        diagnosticsLabel.numberOfLines = 0
        diagnosticsLabel.textColor = .secondaryLabel
        diagnosticsLabel.accessibilityIdentifier = "lab.diagnostics"

        resetButton.configuration?.title = String(localized: "Reset")
        resetButton.accessibilityIdentifier = "lab.reset"
        resetButton.addAction(UIAction { [weak self] _ in self?.reset() }, for: .primaryActionTriggered)

        let tintRow = Self.row([tintControl, UIView(), Self.caption(String(localized: "Enabled")), enabledSwitch])
        let motionRow = Self.row([pauseButton, UIView(), Self.caption(String(localized: "Frame ID")), overlaySwitch])
        // The still pattern has no clock and no frame-ID strip.
        motionRow.isHidden = mode == .pattern
        // Lifecycle checks: hide the stage, or open a second window where
        // the system supports several (iPad).
        let lifecycleRow = Self.row([newWindowButton, closeWindowButton, UIView(), Self.caption(String(localized: "Stage")), stageSwitch])
        newWindowButton.isHidden = !UIApplication.shared.supportsMultipleScenes
        closeWindowButton.isHidden = newWindowButton.isHidden
        let stack = UIStackView(arrangedSubviews: [tintRow, motionRow, lifecycleRow, diagnosticsLabel, resetButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(stack)
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.alwaysBounceVertical = false
        view.addSubview(controls)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controls.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: controls.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: controls.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: controls.contentLayoutGuide.bottomAnchor, constant: -12),
            stack.widthAnchor.constraint(equalTo: controls.frameLayoutGuide.widthAnchor),
        ])
    }

    private static func row(_ views: [UIView]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        return row
    }

    /// A label that describes the switch after it; the switch carries the
    /// accessibility label, so this one is hidden from VoiceOver.
    private static func caption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.isAccessibilityElement = false
        return label
    }

    /// The stage keeps a fixed share of the screen, so text changes in the
    /// controls never resize the rendered surface.
    private func setUpLayout() {
        let safe = view.safeAreaLayoutGuide
        let shared = [
            stage.topAnchor.constraint(equalTo: view.topAnchor),
            stage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        ]
        NSLayoutConstraint.activate(shared)
        portraitConstraints = [
            stage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: controls.topAnchor),
            controls.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            controls.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.38),
        ]
        landscapeConstraints = [
            stage.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stage.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -16),
            controls.topAnchor.constraint(equalTo: safe.topAnchor),
            controls.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            controls.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            controls.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.34),
        ]
    }

    // MARK: Custom rendering

    private func setUpCustomRendering() {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw LabFailure.noMetalDevice }
            guard let queue = device.makeCommandQueue() else { throw LabFailure.noCommandQueue }
            queue.label = "GlassWeaveLab"
            let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
            surface.accessibilityIdentifier = "lab.customSurface"
            surface.translatesAutoresizingMaskIntoConstraints = false
            surface.renderObserver = { [weak self] _ in self?.renderDidFinish() }
            surface.visibilityHandler = { [weak self] visible in self?.surfaceVisibilityChanged(visible) }
            stage.insertSubview(surface, at: 0)
            NSLayoutConstraint.activate([
                surface.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
                surface.topAnchor.constraint(equalTo: stage.topAnchor),
                surface.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            ])
            let stageRendering = CustomStage(
                surface: surface,
                background: try ProceduralBackground(device: device),
                pattern: PatternSource(queue: queue)
            )
            custom = .success(stageRendering)
            if mode == .moving {
                surface.setFrameProducer { [weak self] commandBuffer, pixelSize in
                    self?.produceFrame(into: commandBuffer, pixelSize: pixelSize)
                }
            }
        } catch {
            let label = UILabel()
            label.text = String(describing: error)
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            stage.insertSubview(label, at: 0)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: stage.layoutMarginsGuide.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: stage.layoutMarginsGuide.trailingAnchor),
                label.topAnchor.constraint(equalTo: stage.safeAreaLayoutGuide.topAnchor, constant: 8),
            ])
            custom = .failure(error)
        }
    }

    private enum LabFailure: Error, CustomStringConvertible {
        case noMetalDevice
        case noCommandQueue

        var description: String {
            switch self {
            case .noMetalDevice: "No Metal device is available."
            case .noCommandQueue: "Could not create a command queue."
            }
        }
    }

    /// The panel's optics. Lengths are points; coefficients are normalized.
    /// The tint follows the appearance so the native text on the panel stays
    /// readable over the moving background.
    private func panelParameters() -> GlassParameters {
        let dark = traitCollection.userInterfaceStyle == .dark
        let tint = dark
            ? GlassTint(red: 0.08, green: 0.09, blue: 0.12, strength: 0.45)
            : GlassTint(red: 0.97, green: 0.98, blue: 1.0, strength: 0.45)
        return GlassParameters(cornerRadius: 30, bezelWidth: 22, refraction: 0.85, edgeHighlight: 0.6, tint: tint)
    }

    /// Makes the glass panel follow the native panel content's frame, in the
    /// surface's points. Called from the stage's layout pass, after its
    /// subviews have their frames.
    private func updateCustomPanel() {
        guard case let .success(stageRendering) = custom else { return }
        let surface = stageRendering.surface
        let frame = customPanel.convert(customPanel.bounds, to: surface)
        stripCenterY = frame.maxY - 34
        do {
            try surface.setPanel(GlassPanel(frame: frame, parameters: panelParameters()))
        } catch {
            custom = .failure(error)
        }
    }

    // MARK: Moving source

    private func setUpClock() {
        guard mode == .moving else { return }
        let link = UIUpdateLink(view: stage) { [weak self] _, _ in
            self?.tick()
        }
        link.requiresContinuousUpdates = true
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        updateLink = link
    }

    /// One clock step: advance content time and draw one produced frame.
    private func tick() {
        clock.advance()
        guard case let .success(stageRendering) = custom else { return }
        stageRendering.surface.requestFrame()
    }

    // MARK: Lifecycle checks

    /// Whether the custom surface currently draws. The still pattern and a
    /// failed setup have no clock to run.
    private var surfaceIsVisible: Bool {
        guard case let .success(stageRendering) = custom else { return false }
        return stageRendering.surface.isVisible
    }

    /// Shows or hides the whole stage. The surface notices on its next
    /// request: it stops drawing while hidden and draws the pending frame
    /// once shown again.
    private func applyStageVisibility() {
        stage.isHidden = !stageSwitch.isOn
        if case let .success(stageRendering) = custom {
            stageRendering.surface.requestFrame()
        }
        updateDiagnostics()
    }

    /// While the surface is not visible (stage hidden, scene in the
    /// background, window gone) the background gives its free textures
    /// back. The diagnostics count what the surface submitted meanwhile.
    private func surfaceVisibilityChanged(_ visible: Bool) {
        guard case let .success(stageRendering) = custom else { return }
        let submitted = stageRendering.surface.frameStatistics.submitted
        if visible {
            if let submittedWhenHidden {
                hiddenPeriodSubmissions = submitted - submittedWhenHidden
            }
            submittedWhenHidden = nil
        } else {
            submittedWhenHidden = submitted
            stageRendering.background.trim()
        }
        applyMotionState()
        updateDiagnostics()
    }

    /// Asks the system for another laboratory window, which gets its own
    /// scene, stage, surface, and clock.
    private func openNewWindow() {
        let options = UIWindowScene.ActivationRequestOptions()
        options.requestingScene = view.window?.windowScene
        let request = UISceneSessionActivationRequest(role: .windowApplication, options: options)
        UIApplication.shared.activateSceneSession(for: request) { [weak self] error in
            Task { @MainActor in
                self?.diagnosticsLabel.text = "New window failed: \(error)"
            }
        }
    }

    /// Closes this window's scene session.
    private func closeWindow() {
        guard let session = view.window?.windowScene?.session else { return }
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { [weak self] error in
            Task { @MainActor in
                self?.diagnosticsLabel.text = "Close window failed: \(error)"
            }
        }
    }

    @objc private func reduceMotionChanged() {
        applyMotionState()
        updateDiagnostics()
    }

    /// Runs the clock while the user wants motion, Reduce Motion is off, and
    /// the surface is visible: a hidden stage needs no new frames, so the
    /// clock stops instead of asking the surface for frames it would defer.
    private func applyMotionState() {
        let running = mode == .moving && wantsMotion && !UIAccessibility.isReduceMotionEnabled && surfaceIsVisible
        updateLink?.isEnabled = running
        pauseButton.configuration?.title = wantsMotion ? String(localized: "Pause") : String(localized: "Resume")
    }

    /// Produces the frame for the current clock time inside the draw's
    /// command buffer. The frame-ID strip runs through the panel interior.
    private func produceFrame(into commandBuffer: any MTLCommandBuffer, pixelSize: (width: Int, height: Int)) -> BackgroundFrameLease? {
        guard case let .success(stageRendering) = custom else { return nil }
        let scale = Double(stageRendering.surface.traitCollection.displayScale)
        let frameID = nextFrameID
        let lease = stageRendering.background.encodeFrame(
            into: commandBuffer,
            pixelSize: pixelSize,
            frameID: frameID,
            contentSeconds: clock.seconds,
            displayScale: scale,
            stripCenterY: showsFrameID ? Double(stripCenterY) * scale : nil
        ) { [weak self] release in
            Task { @MainActor in self?.frameReleased(release) }
        }
        if lease != nil { nextFrameID += 1 }
        return lease
    }

    /// Records a released frame. While the surface is not drawing, nothing
    /// else refreshes the diagnostics, so a release does.
    private func frameReleased(_ release: BackgroundFrameRelease) {
        lastRelease = release
        if case let .success(stageRendering) = custom, !stageRendering.surface.isVisible {
            updateDiagnostics()
        }
    }

    /// Diagnostics follow the frames, at most ten times a second while the
    /// clock runs, so the label does not churn at the display rate.
    private func renderDidFinish() {
        if mode == .pattern || clock.ticks % 6 == 0 || updateLink?.isEnabled != true {
            updateDiagnostics()
        }
    }

    // MARK: Still pattern

    /// Hands the surface a newly uploaded pattern frame. The previous frame's
    /// lease is released once the surface lets go of it and every draw that
    /// sampled it has completed.
    private func presentNextPatternFrame() {
        guard case let .success(stageRendering) = custom else { return }
        let frameID = nextFrameID
        nextFrameID += 1
        do {
            let lease = try stageRendering.pattern.makeFrame(frameID: frameID) { [weak self] release in
                Task { @MainActor in
                    self?.lastRelease = release
                    self?.updateDiagnostics()
                }
            }
            try stageRendering.surface.setSource(lease)
            // The laboratory hands each frame to one surface only.
            lease.retire()
        } catch {
            custom = .failure(error)
        }
    }

    // MARK: Native reference

    /// The glass tints the laboratory compares.
    enum NativeTint: Int, CaseIterable {
        case none, blue, orange

        var title: String {
            switch self {
            case .none: String(localized: "None")
            case .blue: String(localized: "Blue")
            case .orange: String(localized: "Orange")
            }
        }

        var color: UIColor? {
            switch self {
            case .none: nil
            case .blue: .systemBlue
            case .orange: .systemOrange
            }
        }

        var diagnosticName: String {
            switch self {
            case .none: "none"
            case .blue: "blue"
            case .orange: "orange"
            }
        }
    }

    /// Applies the tint and enabled state the controls show. A disabled
    /// control also gets non-interactive glass.
    private func applyNativeState() {
        let tint = NativeTint(rawValue: tintControl.selectedSegmentIndex) ?? .none
        let enabled = enabledSwitch.isOn
        nativeGlass.configuration = NativeGlassView.Configuration(tintColor: tint.color, isInteractive: enabled)
        nativeButton.isEnabled = enabled
        updateDiagnostics()
    }

    /// Restores untinted, enabled, interactive glass and clears the tap count.
    private func resetNativeReference() {
        tintControl.selectedSegmentIndex = NativeTint.none.rawValue
        enabledSwitch.isOn = true
        nativeTapCount = 0
        applyNativeState()
    }

    // MARK: Diagnostics

    private func updateDiagnostics() {
        let tint = NativeTint(rawValue: tintControl.selectedSegmentIndex) ?? .none
        let motion: String = switch (mode, updateLink?.isEnabled == true) {
        case (.pattern, _): "still pattern"
        case (.moving, true): "running"
        case (.moving, false):
            if !wantsMotion { "paused" } else if UIAccessibility.isReduceMotionEnabled { "paused (Reduce Motion)" } else { "paused (hidden)" }
        }
        var lines = [
            Self.gpuDescription(),
            "Resets: \(resetCount)",
            "Clock: \(motion) · t \(String(format: "%.2f", clock.seconds)) s · frame ID overlay \(showsFrameID ? "on" : "off")",
            "Native taps: \(nativeTapCount) · tint \(tint.diagnosticName) · \(nativeButton.isEnabled ? "enabled" : "disabled")",
            "Custom taps: \(customTapCount)",
        ]
        switch custom {
        case let .success(stageRendering):
            let surface = stageRendering.surface
            let frame = surface.renderer.currentFrame.map { "frame \($0.frameID)" } ?? "no frame"
            let size = "\(surface.pixelSize.width)×\(surface.pixelSize.height) px"
            let outcome = surface.lastRenderOutcome.map(Self.describe) ?? "not drawn"
            lines.append("Custom: \(frame) · \(size) · \(outcome)")
            let statistics = surface.frameStatistics
            lines.append("Surface: \(surface.isVisible ? "visible" : "hidden") · scene \(Self.describe(view.window?.windowScene?.activationState))")
            lines.append("Frames: \(statistics.submitted) submitted · \(statistics.framesInFlight) in flight (peak \(statistics.peakFramesInFlight) of \(GlassSurfaceView.maximumFramesInFlight)) · \(statistics.deferredWhileHidden) deferred hidden · \(statistics.deferredAtLimit) at limit · \(statistics.coalesced) coalesced")
            if let hiddenPeriodSubmissions {
                lines.append("Last hidden period: \(hiddenPeriodSubmissions) submitted")
            }
            if mode == .moving {
                let background = stageRendering.background
                let pool = background.poolStatistics
                let produced = background.lastProduced.map { "produced frame \($0.frameID) at t \(String(format: "%.2f", $0.contentSeconds)) s" } ?? "nothing produced"
                lines.append("Source: \(produced) · \(pool.liveTextures) textures (\(pool.allocations) allocated) · \(pool.exhaustedCheckouts) coalesced")
            }
            if let error = surface.lastProducedFrameError {
                lines.append("Rejected frame: \(error)")
            }
        case let .failure(error):
            lines.append("Custom unavailable: \(error)")
        case nil:
            break
        }
        if let lastRelease {
            lines.append("Released frame \(lastRelease.frameID): \(lastRelease.completedSubmissions) drawn, \(lastRelease.skippedSubmissions) skipped")
        }
        diagnosticsLabel.text = lines.joined(separator: "\n")
    }

    private static func describe(_ state: UIScene.ActivationState?) -> String {
        switch state {
        case .foregroundActive: "active"
        case .foregroundInactive: "inactive"
        case .background: "background"
        case .unattached: "unattached"
        case nil: "none"
        @unknown default: "unknown"
        }
    }

    private static func describe(_ outcome: BackgroundRenderOutcome) -> String {
        switch outcome {
        case let .submitted(frameID): "submitted frame \(frameID)"
        case let .skipped(reason): "skipped (\(reason))"
        }
    }

    private static func gpuDescription() -> String {
        guard let device = MTLCreateSystemDefaultDevice() else { return "No Metal device" }
        let capabilities = RenderCapabilities(device: device)
        let family = capabilities.highestAppleFamily.map { "apple\($0)" } ?? "none"
        return "GPU \(capabilities.deviceName) · Metal 3 \(capabilities.supportsMetal3) · Metal 4 \(capabilities.supportsMetal4) · \(family)"
    }
}

/// The stage reports each layout pass after its subviews have frames, so the
/// glass panel can follow the native panel content exactly.
final class StageView: UIView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        // Lay out the stack holding the panel content first, so its frame is
        // current when the glass panel copies it.
        subviews.forEach { $0.layoutIfNeeded() }
        onLayout?()
    }
}
