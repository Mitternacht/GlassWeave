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
/// instead, for orientation checks. Launching with `-lab.benchmark <mode>`
/// runs one mode of GW-09's fixed workload (``BenchmarkScenario``) with
/// `RenderMetrics` recording. Launching with `-lab.glow <name>` gives the
/// custom panel a colored glow (``LabGlow``, GW-17), with a halo and a pulse
/// for `ember` and `energy` (GW-18); a pulsing preset adds a Pulse switch.
/// Launching with `-lab.nativeGlow <name>` draws the same preset's rim and
/// halo around the native reference glass (``EnhancedNativeGlassView``,
/// GW-14), with a Native glow switch; without it the reference is plain
/// native glass. Launching with `-lab.interior <name>` gives the custom
/// panel an animated interior (``LabInterior``, GW-19) with an Interior
/// motion switch.
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
    /// GW-09's workload, when launched with `-lab.benchmark <mode>`.
    private let benchmark = BenchmarkScenario.fromLaunchArguments()
    /// The panel's glow, when launched with `-lab.glow <name>`.
    private let labGlow = LabGlow.fromLaunchArguments
    /// The native reference's glow, when launched with
    /// `-lab.nativeGlow <name>` (GW-14).
    private let labNativeGlow = LabGlow.fromLaunchArguments(key: "lab.nativeGlow")
    /// The panel's interior, when launched with `-lab.interior <name>`
    /// (GW-19).
    private let labInterior = LabInterior.fromLaunchArguments

    // MARK: Stage

    private let stage = StageView()
    /// Scrolls the stage's native content when it is taller than the stage,
    /// for example at accessibility text sizes. The glass panel follows.
    private let stageScroll = UIScrollView()
    private let content = UIStackView()
    /// Holds the custom panel's native content. Its frame, converted into
    /// the surface's points, is the glass panel's frame.
    private let customPanel = UIView()
    private let customTitle = UILabel()
    private let customButton = UIButton(configuration: .borderedProminent())
    private var customTapCount = 0

    /// Native mode: genuine Apple glass around a real button. Nothing here
    /// creates a GlassWeave renderer; the glass samples whatever the system
    /// composites behind it, which here is the same stage. The glass sits in
    /// an enhanced-native host, which draws nothing until
    /// `-lab.nativeGlow` gives it a glow.
    private let nativeHost = EnhancedNativeGlassView()
    private var nativeGlass: NativeGlassView { nativeHost.glass }
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
    /// Turns a pulsing glow preset's pulse on and off (GW-18), on the custom
    /// panel and the native reference.
    private let pulseSwitch = UISwitch()
    /// Turns the native reference's glow on and off (GW-14).
    private let nativeGlowSwitch = UISwitch()
    /// Moves or stills the panel's interior (GW-19).
    private let interiorMotionSwitch = UISwitch()
    private let diagnosticsLabel = UILabel()
    private let resetButton = UIButton(configuration: .bordered())
    /// Benchmark only: settles the stage and reports allocated bytes.
    private let measureButton = UIButton(configuration: .bordered())
    /// Opens the glow gallery (GW-20).
    private let galleryButton = UIButton(configuration: .bordered())
    /// Whether `-lab.gallery YES` has opened the gallery yet.
    private var openedGalleryAtLaunch = false
    /// Opens the material bench and the light-fields demo (GW-21).
    private let benchButton = UIButton(configuration: .bordered())
    private let lightFieldsButton = UIButton(configuration: .bordered())
    private let lensButton = UIButton(configuration: .bordered())
    private let chromeButton = UIButton(configuration: .bordered())
    private let paperButton = UIButton(configuration: .bordered())
    /// Opens the shapes page (GW-26).
    private let shapesButton = UIButton(configuration: .bordered())
    /// Opens the liquid vessels page (GW-28).
    private let vesselButton = UIButton(configuration: .bordered())
    /// Opens native glass beside GlassWeave's on one backdrop (REFINE).
    private let compareButton = UIButton(configuration: .bordered())
    /// Open GW-27's presentation screen and GW-24a's frost pyramid screen.
    private let presentationButton = UIButton(configuration: .bordered())
    private let frostButton = UIButton(configuration: .bordered())
    /// Opens the frosted glass page (GW-24b).
    private let frostGlassButton = UIButton(configuration: .bordered())
    /// Whether `-lab.bench` or `-lab.lightFields` has opened its screen yet.
    private var openedBenchAtLaunch = false
    /// Whether `-lab.versus YES` has opened the Apple vs GlassWeave screen yet.
    private var openedVersusAtLaunch = false
    /// The control rows; vertical at accessibility text sizes.
    private var controlRows: [UIStackView] = []
    /// At accessibility text sizes the custom panel takes the stage's full
    /// width instead of its nominal 320 points.
    private var panelFillsWidth: NSLayoutConstraint?
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

    // MARK: Benchmark state

    /// The surface's trailing and bottom constraints; the lifecycle stress
    /// insets them to resize the surface.
    private var surfaceInsetConstraints: [NSLayoutConstraint] = []
    private var diagnosticsTimer: Task<Void, Never>?
    private var lifecycleStress: Task<Void, Never>?
    private var lifecycleLine: String?
    private var settledLine: String?

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
        // The panel tint keeps its text readable for the appearance and
        // contrast setting.
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (self: Self, _) in
            self.updateCustomPanel()
            self.updateNativeGlow()
            self.updateDiagnostics()
        }
        applyContentSizeLayout()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.applyContentSizeLayout()
        }
        if let benchmark {
            startBenchmark(benchmark)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // `-lab.gallery YES` opens the glow gallery once, at launch.
        if !openedGalleryAtLaunch, UserDefaults.standard.bool(forKey: "lab.gallery") {
            openedGalleryAtLaunch = true
            openGallery(animated: false)
        }
        // `-lab.bench <page>` or `-lab.lightFields YES` opens GW-21's screens
        // once, at launch.
        if !openedBenchAtLaunch {
            let defaults = UserDefaults.standard
            if let page = BenchPage.fromBenchArgument {
                openedBenchAtLaunch = true
                openBench(.bench, page: page, animated: false)
            } else if defaults.bool(forKey: "lab.compare") {
                openedBenchAtLaunch = true
                openBench(.compare, page: BenchPage.named(defaults.string(forKey: "lab.compareBackdrop")) ?? .charcoal, animated: false)
            } else if defaults.bool(forKey: "lab.frostBench") {
                openedBenchAtLaunch = true
                openBench(.frost, page: .prism, animated: false)
            } else if defaults.bool(forKey: "lab.shapes") {
                openedBenchAtLaunch = true
                openShapes(page: BenchPage.named(defaults.string(forKey: "lab.shapesBackdrop")) ?? .charcoal, animated: false)
            } else if defaults.bool(forKey: "lab.vessel") {
                openedBenchAtLaunch = true
                openVessel(animated: false)
            } else if defaults.bool(forKey: "lab.paper") {
                openedBenchAtLaunch = true
                openBench(.paper, page: .paperDesk, animated: false)
            } else if defaults.bool(forKey: "lab.chrome") {
                openedBenchAtLaunch = true
                openBench(.chrome, page: .chrome, animated: false)
            } else if defaults.bool(forKey: "lab.lens") {
                openedBenchAtLaunch = true
                openBench(.lens, page: BenchPage.named(defaults.string(forKey: "lab.lensBackdrop")) ?? .orbs, animated: false)
            } else if defaults.bool(forKey: "lab.lightFields") {
                openedBenchAtLaunch = true
                openBench(.lightFields, page: BenchPage.named(defaults.string(forKey: "lab.lightBackdrop")) ?? .charcoal, animated: false)
            }
        }
        // `-lab.versus YES` opens the Apple vs GlassWeave screen once (GW-29a).
        if !openedVersusAtLaunch, VersusViewController.launchRequested {
            openedVersusAtLaunch = true
            VersusViewController.present(from: self, animated: false)
        }
    }

    /// Presents the material bench or the light-fields demo (GW-21) over the
    /// whole window.
    private func openBench(_ mode: MaterialBenchViewController.Mode, page: BenchPage, animated: Bool) {
        guard presentedViewController == nil else { return }
        let bench = MaterialBenchViewController(mode: mode, page: page)
        bench.modalPresentationStyle = .fullScreen
        present(bench, animated: animated)
    }

    /// Presents the shapes page (GW-26) over the whole window.
    private func openShapes(page: BenchPage, animated: Bool) {
        guard presentedViewController == nil else { return }
        let shapes = ShapesBenchViewController(page: page)
        shapes.modalPresentationStyle = .fullScreen
        present(shapes, animated: animated)
    }

    /// Presents the liquid vessels page (GW-28) over the whole window.
    private func openVessel(animated: Bool) {
        guard presentedViewController == nil else { return }
        let vessel = VesselBenchViewController(page: .stage)
        vessel.modalPresentationStyle = .fullScreen
        present(vessel, animated: animated)
    }

    /// Presents the glow gallery (GW-20) over the whole window. While it is
    /// shown this screen is out of the window, so its surface draws nothing.
    private func openGallery(animated: Bool) {
        guard presentedViewController == nil else { return }
        let gallery = GlowGalleryViewController()
        gallery.modalPresentationStyle = .fullScreen
        present(gallery, animated: animated)
    }

    /// At accessibility text sizes, control rows stack vertically and the
    /// custom panel uses the full stage width, so text wraps instead of
    /// being cut off; the stage and the controls scroll.
    private func applyContentSizeLayout() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        for row in controlRows {
            row.axis = large ? .vertical : .horizontal
            row.alignment = large ? .leading : .center
        }
        panelFillsWidth?.isActive = large
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
        // A benchmark freezes the source in its idle mode and starts with
        // the frame-ID strip off, as timing requires.
        wantsMotion = benchmark?.mode.freezesSource != true
        showsFrameID = benchmark == nil
        overlaySwitch.isOn = showsFrameID
        settledLine = nil
        if case let .success(stage) = custom {
            stage.surface.renderer.metrics?.reset()
        }
        stageSwitch.isOn = true
        pulseSwitch.isOn = true
        nativeGlowSwitch.isOn = true
        interiorMotionSwitch.isOn = true
        updateNativeGlow()
        // Before the first layout the stage lays the panel out itself.
        if stage.bounds.width > 0 {
            updateCustomPanel()
        }
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
        // Never truncate: a word wider than the panel wraps by character.
        customTitle.lineBreakMode = .byWordWrapping

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
        if let override = Self.accessibilitySettingsOverride {
            nativeHost.accessibilitySettingsSource = .fixed(override)
        }

        referenceCaption.text = String(localized: "Native reference")
        referenceCaption.font = .preferredFont(forTextStyle: .footnote)
        referenceCaption.adjustsFontForContentSizeCategory = true
        referenceCaption.textColor = .label
        referenceCaption.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.75)
        referenceCaption.layer.cornerRadius = 6
        referenceCaption.layer.masksToBounds = true

        let reference = UIStackView(arrangedSubviews: [referenceCaption, nativeHost])
        reference.axis = .vertical
        reference.alignment = .center
        // The native glow's halo spills outside the glass; keep the caption
        // and the custom panel clear of it.
        let nativeHalo = CGFloat(labNativeGlow?.glow(for: traitCollection).haloRadius ?? 0)
        reference.spacing = 6 + nativeHalo
        // A benchmark mode shows only its own composition.
        if let benchmark {
            reference.isHidden = !benchmark.mode.showsNativeReference
            customPanel.isHidden = !benchmark.mode.showsCustomPanel
        }

        content.addArrangedSubview(customPanel)
        content.addArrangedSubview(reference)
        content.axis = .vertical
        content.alignment = .center
        content.spacing = 20 + nativeHalo
        content.translatesAutoresizingMaskIntoConstraints = false
        // The content is centered in the stage's safe area while it fits and
        // scrolls when it does not.
        // The host reports its own layout passes too: content inside the
        // scroll view can lay out again without the stage doing so.
        let contentHost = StageView()
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.onLayout = { [weak self] in self?.updateCustomPanel() }
        contentHost.addSubview(content)
        stageScroll.addSubview(contentHost)
        stageScroll.translatesAutoresizingMaskIntoConstraints = false
        stageScroll.contentInsetAdjustmentBehavior = .never
        // Content scrolls under the status bar like the glass panel drawn
        // behind it; the stage itself clips at its edges.
        stageScroll.clipsToBounds = false
        stageScroll.accessibilityIdentifier = "lab.stageScroll"
        stageScroll.delegate = self
        stage.addSubview(stageScroll)

        let safe = stage.safeAreaLayoutGuide
        let scroll = stageScroll
        let fillsFrame = contentHost.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        fillsFrame.priority = .defaultLow
        // Nominal 320 x 180 points, narrower when the stage is.
        let preferredWidth = customPanel.widthAnchor.constraint(equalToConstant: 320)
        preferredWidth.priority = .defaultHigh
        // In a benchmark the stage fills the screen behind the controls, and
        // the native content stays in the part the controls leave free; the
        // orientation layouts in setUpLayout() place its trailing and bottom
        // edges.
        if benchmark == nil {
            NSLayoutConstraint.activate([
                scroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: safe.topAnchor),
            contentHost.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            contentHost.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            contentHost.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
            fillsFrame,
            content.centerXAnchor.constraint(equalTo: contentHost.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: contentHost.leadingAnchor, constant: 16),
            content.topAnchor.constraint(greaterThanOrEqualTo: contentHost.topAnchor, constant: 8),
            preferredWidth,
            customPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            panelContent.centerXAnchor.constraint(equalTo: customPanel.centerXAnchor),
            panelContent.centerYAnchor.constraint(equalTo: customPanel.centerYAnchor, constant: -14),
            // Keep the text out of the 22-point rim, where refraction and
            // edge illumination act.
            panelContent.leadingAnchor.constraint(greaterThanOrEqualTo: customPanel.leadingAnchor, constant: 24),
            panelContent.topAnchor.constraint(greaterThanOrEqualTo: customPanel.topAnchor, constant: 24),
            panelContent.bottomAnchor.constraint(lessThanOrEqualTo: customPanel.bottomAnchor, constant: -48),
            nativeButton.leadingAnchor.constraint(equalTo: nativeGlass.contentView.leadingAnchor, constant: 20),
            nativeButton.trailingAnchor.constraint(equalTo: nativeGlass.contentView.trailingAnchor, constant: -20),
            nativeButton.topAnchor.constraint(equalTo: nativeGlass.contentView.topAnchor, constant: 8),
            nativeButton.bottomAnchor.constraint(equalTo: nativeGlass.contentView.bottomAnchor, constant: -8),
        ])
        panelFillsWidth = customPanel.widthAnchor.constraint(equalTo: contentHost.widthAnchor, constant: -32)
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

        pulseSwitch.accessibilityIdentifier = "lab.glowPulse"
        pulseSwitch.accessibilityLabel = String(localized: "Glow pulse")
        pulseSwitch.isOn = true
        pulseSwitch.addAction(UIAction { [weak self] _ in
            self?.updateCustomPanel()
            self?.updateNativeGlow()
            self?.updateDiagnostics()
        }, for: .valueChanged)
        nativeGlowSwitch.accessibilityIdentifier = "lab.nativeGlowEnabled"
        nativeGlowSwitch.accessibilityLabel = String(localized: "Native glow")
        nativeGlowSwitch.isOn = true
        nativeGlowSwitch.addAction(UIAction { [weak self] _ in
            self?.updateNativeGlow()
            self?.updateDiagnostics()
        }, for: .valueChanged)
        interiorMotionSwitch.accessibilityIdentifier = "lab.interiorMotion"
        interiorMotionSwitch.accessibilityLabel = String(localized: "Interior motion")
        interiorMotionSwitch.isOn = true
        interiorMotionSwitch.addAction(UIAction { [weak self] _ in
            self?.updateCustomPanel()
            self?.updateDiagnostics()
        }, for: .valueChanged)

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

        measureButton.configuration?.title = String(localized: "Settle and measure")
        measureButton.accessibilityIdentifier = "lab.measure"
        measureButton.addAction(UIAction { [weak self] _ in
            Task { [weak self] in
                guard let self, let settled = await measureSettled() else { return }
                settledLine = "Settled: \(settled.line)"
                updateDiagnostics()
            }
        }, for: .primaryActionTriggered)
        measureButton.isHidden = benchmark == nil

        galleryButton.configuration?.title = String(localized: "Glow gallery")
        galleryButton.accessibilityIdentifier = "lab.openGallery"
        galleryButton.addAction(UIAction { [weak self] _ in self?.openGallery(animated: true) }, for: .primaryActionTriggered)
        galleryButton.isHidden = benchmark != nil

        benchButton.configuration?.title = String(localized: "Material bench")
        benchButton.accessibilityIdentifier = "lab.openBench"
        benchButton.addAction(UIAction { [weak self] _ in self?.openBench(.bench, page: .dotGrid, animated: true) }, for: .primaryActionTriggered)
        benchButton.isHidden = benchmark != nil
        lightFieldsButton.configuration?.title = String(localized: "Light fields")
        lightFieldsButton.accessibilityIdentifier = "lab.openLightFields"
        lightFieldsButton.addAction(UIAction { [weak self] _ in self?.openBench(.lightFields, page: .charcoal, animated: true) }, for: .primaryActionTriggered)
        lightFieldsButton.isHidden = benchmark != nil
        lensButton.configuration?.title = String(localized: "Thick lens")
        lensButton.accessibilityIdentifier = "lab.openLens"
        lensButton.addAction(UIAction { [weak self] _ in self?.openBench(.lens, page: .orbs, animated: true) }, for: .primaryActionTriggered)
        lensButton.isHidden = benchmark != nil
        chromeButton.configuration?.title = String(localized: "Chrome and light")
        chromeButton.accessibilityIdentifier = "lab.openChrome"
        chromeButton.addAction(UIAction { [weak self] _ in self?.openBench(.chrome, page: .chrome, animated: true) }, for: .primaryActionTriggered)
        chromeButton.isHidden = benchmark != nil
        paperButton.configuration?.title = String(localized: "Paper desk")
        paperButton.accessibilityIdentifier = "lab.openPaper"
        paperButton.addAction(UIAction { [weak self] _ in self?.openBench(.paper, page: .paperDesk, animated: true) }, for: .primaryActionTriggered)
        paperButton.isHidden = benchmark != nil
        shapesButton.configuration?.title = String(localized: "Shapes")
        shapesButton.accessibilityIdentifier = "lab.openShapes"
        shapesButton.addAction(UIAction { [weak self] _ in self?.openShapes(page: .charcoal, animated: true) }, for: .primaryActionTriggered)
        shapesButton.isHidden = benchmark != nil
        vesselButton.configuration?.title = String(localized: "Liquid vessels")
        vesselButton.accessibilityIdentifier = "lab.openVessel"
        vesselButton.addAction(UIAction { [weak self] _ in self?.openVessel(animated: true) }, for: .primaryActionTriggered)
        vesselButton.isHidden = benchmark != nil
        compareButton.configuration?.title = String(localized: "Native vs refined glass")
        compareButton.accessibilityIdentifier = "lab.openCompare"
        compareButton.addAction(UIAction { [weak self] _ in self?.openBench(.compare, page: .charcoal, animated: true) }, for: .primaryActionTriggered)
        compareButton.isHidden = benchmark != nil
        presentationButton.configuration?.title = String(localized: "Presentation")
        presentationButton.accessibilityIdentifier = "lab.openPresentation"
        presentationButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            LabPageHostViewController.presentPresentation(from: self, animated: true)
        }, for: .primaryActionTriggered)
        presentationButton.isHidden = benchmark != nil
        frostButton.configuration?.title = String(localized: "Frost pyramid")
        frostButton.accessibilityIdentifier = "lab.openFrost"
        frostButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            LabPageHostViewController.presentFrost(from: self, animated: true)
        }, for: .primaryActionTriggered)
        frostButton.isHidden = benchmark != nil
        frostGlassButton.configuration?.title = String(localized: "Frosted glass")
        frostGlassButton.accessibilityIdentifier = "lab.openFrostGlass"
        frostGlassButton.addAction(UIAction { [weak self] _ in self?.openBench(.frost, page: .prism, animated: true) }, for: .primaryActionTriggered)
        frostGlassButton.isHidden = benchmark != nil

        let tintRow = Self.row([tintControl, UIView(), Self.caption(String(localized: "Enabled")), enabledSwitch])
        let motionRow = Self.row([pauseButton, UIView(), Self.caption(String(localized: "Frame ID")), overlaySwitch])
        // The still pattern has no clock and no frame-ID strip.
        motionRow.isHidden = mode == .pattern
        // Lifecycle checks: hide the stage, or open a second window where
        // the system supports several (iPad).
        let lifecycleRow = Self.row([newWindowButton, closeWindowButton, UIView(), Self.caption(String(localized: "Stage")), stageSwitch])
        // A pulsing glow preset can be settled to compare frame counts.
        // A pulsing preset (custom or native) can be settled; each caption
        // sits beside its own switch, which carries the label.
        let glowRow = Self.row([UIView(), Self.caption(String(localized: "Pulse")), pulseSwitch])
        glowRow.isHidden = labGlow?.pulses != true && labNativeGlow?.pulses != true
        // The native reference's glow can be turned off to compare (GW-14).
        let nativeGlowRow = Self.row([UIView(), Self.caption(String(localized: "Native glow")), nativeGlowSwitch])
        nativeGlowRow.isHidden = labNativeGlow == nil
        // The panel's interior can be stilled to compare frame counts (GW-19).
        let interiorRow = Self.row([UIView(), Self.caption(String(localized: "Interior motion")), interiorMotionSwitch])
        interiorRow.isHidden = labInterior == nil
        controlRows = [tintRow, motionRow, lifecycleRow, glowRow, nativeGlowRow, interiorRow]
        newWindowButton.isHidden = !UIApplication.shared.supportsMultipleScenes
        closeWindowButton.isHidden = newWindowButton.isHidden
        let stack = UIStackView(arrangedSubviews: [tintRow, motionRow, lifecycleRow, glowRow, nativeGlowRow, interiorRow, diagnosticsLabel, resetButton, galleryButton, VersusViewController.menuButton(presentedBy: self, hidden: benchmark != nil), StudyViewController.menuButton(presentedBy: self, hidden: benchmark != nil), SwiftUIExample.menuButton(presentedBy: self, hidden: benchmark != nil), lightFieldsButton, lensButton, chromeButton, paperButton, shapesButton, vesselButton, compareButton, presentationButton, frostButton, frostGlassButton, benchButton, measureButton])
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
        label.numberOfLines = 0
        return label
    }

    /// The stage keeps a fixed share of the screen, so text changes in the
    /// controls never resize the rendered surface.
    ///
    /// In a benchmark the stage, and so the rendered surface, fills the
    /// whole screen, as the validation protocol's workload requires; the
    /// controls sit above it on an opaque background, and the native content
    /// stays in the part of the stage the controls leave free.
    private func setUpLayout() {
        let safe = view.safeAreaLayoutGuide
        let shared = [
            stage.topAnchor.constraint(equalTo: view.topAnchor),
            stage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        ]
        NSLayoutConstraint.activate(shared)
        let portraitControls = [
            controls.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            controls.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.38),
        ]
        let landscapeControls = [
            controls.topAnchor.constraint(equalTo: safe.topAnchor),
            controls.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            controls.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            controls.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.34),
        ]
        guard benchmark != nil else {
            portraitConstraints = portraitControls + [
                stage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                stage.bottomAnchor.constraint(equalTo: controls.topAnchor),
            ]
            landscapeConstraints = landscapeControls + [
                stage.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                stage.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -16),
            ]
            return
        }
        // An opaque backdrop a little larger than the controls keeps them
        // legible over the moving surface.
        let backdrop = UIView()
        backdrop.backgroundColor = .systemBackground
        backdrop.layer.cornerRadius = 20
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(backdrop, belowSubview: controls)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -12),
            backdrop.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: 12),
            backdrop.topAnchor.constraint(equalTo: controls.topAnchor, constant: -12),
            backdrop.bottomAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
        ])
        let fullScreen = [
            stage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        let stageSafe = stage.safeAreaLayoutGuide
        portraitConstraints = portraitControls + fullScreen + [
            stageScroll.trailingAnchor.constraint(equalTo: stageSafe.trailingAnchor),
            stageScroll.bottomAnchor.constraint(equalTo: backdrop.topAnchor),
        ]
        landscapeConstraints = landscapeControls + [
            stage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stageScroll.trailingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: -8),
            stageScroll.bottomAnchor.constraint(equalTo: stageSafe.bottomAnchor),
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
            if let override = Self.accessibilitySettingsOverride {
                surface.accessibilitySettingsSource = .fixed(override)
            }
            surface.accessibilitySettingsHandler = { [weak self] _ in
                self?.applyMotionState()
                self?.updateDiagnostics()
            }
            stage.insertSubview(surface, at: 0)
            surfaceInsetConstraints = [
                surface.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
                surface.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            ]
            NSLayoutConstraint.activate(surfaceInsetConstraints + [
                surface.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
                surface.topAnchor.constraint(equalTo: stage.topAnchor),
            ])
            if benchmark != nil {
                surface.renderer.metrics = RenderMetrics()
            }
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
        var tint = dark
            ? GlassTint(red: 0.08, green: 0.09, blue: 0.12, strength: 0.45)
            : GlassTint(red: 0.97, green: 0.98, blue: 1.0, strength: 0.45)
        // Raise the strength until the panel's label text keeps the target
        // contrast over any background (GlassWeave's legibility rule).
        if let minimum = tint.minimumStrength(forContrast: panelContrastTarget, againstTextLuminance: panelTextLuminance) {
            tint.strength = max(tint.strength, (minimum * 100).rounded(.up) / 100)
        }
        var glow = labGlow?.glow(for: traitCollection) ?? .none
        if !pulseSwitch.isOn {
            glow.pulseDepth = 0
        }
        var interior = labInterior?.interior(for: traitCollection) ?? .none
        if !interiorMotionSwitch.isOn {
            interior.speed = 0
        }
        return GlassParameters(
            cornerRadius: 30, bezelWidth: 22, refraction: 0.85, edgeHighlight: 0.6, tint: tint,
            glow: glow, interior: interior
        )
    }

    /// WCAG contrast the panel text must keep: 4.5:1, or 7:1 when Increase
    /// Contrast is on.
    private var panelContrastTarget: Double {
        traitCollection.accessibilityContrast == .high ? 7 : 4.5
    }

    /// The relative luminance of the panel's text color (`label`) in the
    /// current appearance.
    private var panelTextLuminance: Double {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor.label.resolvedColor(with: traitCollection).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let unit = { (value: CGFloat) in min(max(Double(value), 0), 1) }
        return GlassTint.relativeLuminance(red: unit(red), green: unit(green), blue: unit(blue))
    }

    /// Makes the glass panel follow the native panel content's frame, in the
    /// surface's points. Called from the stage's layout pass, after its
    /// subviews have their frames.
    private func updateCustomPanel() {
        guard case let .success(stageRendering) = custom else { return }
        let surface = stageRendering.surface
        guard benchmark?.mode.showsCustomPanel != false else {
            // Benchmark modes 1 and 2 draw the background alone.
            try? surface.setPanel(nil)
            return
        }
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
        // UIKit reports no ancestor's hiding; the native glow looks again at
        // its next layout pass, which this asks for.
        nativeHost.setNeedsLayout()
        nativeHost.layoutIfNeeded()
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

    /// The accessibility settings the custom surface applies; the clock
    /// follows the same Reduce Motion value.
    private var accessibilitySettings: GlassAccessibilitySettings {
        if case let .success(stageRendering) = custom {
            return stageRendering.surface.accessibilitySettings
        }
        return .system
    }

    /// Fixed accessibility settings from launch arguments
    /// (`-lab.reduceMotion YES`, `-lab.reduceTransparency YES`), for UI tests
    /// and comparison runs; `nil` follows the system. The glow gallery reads
    /// them too.
    static var accessibilitySettingsOverride: GlassAccessibilitySettings? {
        let defaults = UserDefaults.standard
        let keys = ["lab.reduceMotion", "lab.reduceTransparency"]
        guard keys.contains(where: { defaults.object(forKey: $0) != nil }) else { return nil }
        let system = GlassAccessibilitySettings.system
        func value(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        return GlassAccessibilitySettings(
            reduceTransparency: value("lab.reduceTransparency", system.reduceTransparency),
            reduceMotion: value("lab.reduceMotion", system.reduceMotion)
        )
    }

    /// Runs the clock while the user wants motion, Reduce Motion is off, and
    /// the surface is visible: a hidden stage needs no new frames, so the
    /// clock stops instead of asking the surface for frames it would defer.
    private func applyMotionState() {
        let running = mode == .moving && wantsMotion && !accessibilitySettings.reduceMotion && surfaceIsVisible
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

    /// Diagnostics follow the frames, about four times a second while the
    /// clock runs, so laying out the label (large at accessibility text
    /// sizes) does not compete with the display rate.
    private func renderDidFinish() {
        // A benchmark refreshes from its own timer, not from frames.
        guard benchmark == nil else { return }
        // While the glow pulses, frames come from the surface's effect clock;
        // refresh about four times a second then too.
        let pulsing: Bool = if case let .success(stage) = custom { stage.surface.isAnimating } else { false }
        let pulseFrame: Bool = if case let .success(stage) = custom { stage.surface.frameStatistics.submitted % 15 == 0 } else { true }
        if mode == .pattern ? (!pulsing || pulseFrame) : (clock.ticks % 15 == 0 || updateLink?.isEnabled != true) {
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

    /// The native reference's glow: the `-lab.nativeGlow` preset with its
    /// system colors resolved for the current traits, without its pulse when
    /// the Pulse switch is off, or none when the Native glow switch is off.
    private func updateNativeGlow() {
        var glow = nativeGlowSwitch.isOn ? labNativeGlow?.glow(for: traitCollection) ?? .none : .none
        if !pulseSwitch.isOn {
            glow.pulseDepth = 0
        }
        // The presets are finite, so the view never rejects them.
        try? nativeHost.setGlow(glow)
    }

    /// Restores untinted, enabled, interactive glass and clears the tap count.
    private func resetNativeReference() {
        tintControl.selectedSegmentIndex = NativeTint.none.rawValue
        enabledSwitch.isOn = true
        nativeTapCount = 0
        applyNativeState()
    }

    // MARK: Benchmark

    /// Starts what a benchmark mode adds: a once-a-second diagnostics
    /// refresh (which requests no frame) and, in mode 5, the lifecycle
    /// stress.
    private func startBenchmark(_ benchmark: BenchmarkScenario) {
        diagnosticsTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.updateDiagnostics()
            }
        }
        if benchmark.mode == .lifecycle {
            runLifecycleStress(seed: benchmark.seed)
        }
    }

    /// Allocated bytes with the stage settled.
    private struct Settled {
        /// The Metal device's `currentAllocatedSize`: everything this process
        /// has allocated on it, including drawables.
        let deviceBytes: Int
        /// Textures the procedural background's pool holds, and their bytes.
        /// The pool is bounded, so growth outside it is what matters.
        let textures: Int
        let poolBytes: Int

        var line: String { "\(deviceBytes) B, \(textures) textures, \(poolBytes) B pooled" }
    }

    /// Stops the clock, waits for every frame in flight to complete and for
    /// the driver to return freed memory, reads the allocations, and restores
    /// motion.
    private func measureSettled() async -> Settled? {
        guard case let .success(stageRendering) = custom else { return nil }
        let surface = stageRendering.surface
        let wanted = wantsMotion
        wantsMotion = false
        applyMotionState()
        let deadline = ContinuousClock.now + .seconds(5)
        while surface.frameStatistics.framesInFlight > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(500))
        let pool = stageRendering.background.poolStatistics
        let settled = Settled(
            deviceBytes: surface.renderer.device.currentAllocatedSize,
            textures: pool.liveTextures,
            poolBytes: pool.liveBytes
        )
        wantsMotion = wanted
        applyMotionState()
        return settled
    }

    /// Cuts `inset` points from the surface's trailing and bottom edges,
    /// which resizes its drawable.
    private func setSurfaceInset(_ inset: CGFloat) {
        for constraint in surfaceInsetConstraints {
            constraint.constant = -inset
        }
    }

    /// Mode 5: after a two-second warm-up, measure settled allocations, run
    /// the seeded hide/show and resize cycles, return to the full size, and
    /// measure again.
    private func runLifecycleStress(seed: UInt64) {
        lifecycleLine = "Lifecycle: warming up"
        lifecycleStress = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let before = await self?.measureSettled() else { return }
            var schedule = LifecycleStressSchedule(seed: seed)
            let cycles = LifecycleStressSchedule.cycles
            for cycle in 1...cycles {
                guard let self else { return }
                lifecycleLine = "Lifecycle: cycle \(cycle) of \(cycles)"
                stageSwitch.isOn = false
                applyStageVisibility()
                try? await Task.sleep(for: .milliseconds(100))
                stageSwitch.isOn = true
                applyStageVisibility()
                try? await Task.sleep(for: .milliseconds(100))
                setSurfaceInset(schedule.nextInset())
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.setSurfaceInset(0)
            try? await Task.sleep(for: .seconds(1))
            guard let self, let after = await measureSettled() else { return }
            lifecycleLine = "Lifecycle: done · \(cycles) cycles · settled before \(before.line) · after \(after.line)"
            updateDiagnostics()
        }
    }

    /// The benchmark's lines: the workload, the renderer's metrics, current
    /// allocations, and lifecycle and settled measurements.
    private func benchmarkDiagnostics(_ benchmark: BenchmarkScenario) -> [String] {
        var lines = [benchmark.summary]
        guard case let .success(stageRendering) = custom else { return lines }
        let renderer = stageRendering.surface.renderer
        if let metrics = renderer.metrics {
            let summary = metrics.summary()
            let counts = summary.counts
            let gpu = summary.gpu.map { "GPU p50/p95/p99 \(Self.milliseconds($0)) ms" } ?? "GPU time not reported"
            let encode = summary.encode.map { "encode p50/p95/p99 \(Self.milliseconds($0)) ms" } ?? "no encode samples"
            let produce = summary.produce.map { "produce p95 \(Self.milliseconds($0.p95)) ms" } ?? "no produce samples"
            let acquire = summary.targetAcquisition.map { "acquire p95 \(Self.milliseconds($0.p95)) ms" } ?? "no acquire samples"
            lines.append("Metrics: \(counts.drawn) frames · \(gpu) · \(encode) · \(produce) · \(acquire) · \(counts.commandBuffersCommitted) committed, \(counts.commandBuffersFailed) failed, \(counts.declinedProductions) declined, \(counts.skipped) skipped")
        }
        let pool = stageRendering.background.poolStatistics
        let bytes = renderer.device.currentAllocatedSize
        // The iOS Simulator reports zero for every allocation size.
        let allocated = bytes > 0
            ? "\(bytes) B allocated (\(String(format: "%.1f", Double(bytes) / 1_048_576)) MiB)"
            : "allocation sizes not reported by this device"
        lines.append("Metal: \(allocated) · pool \(pool.liveTextures) textures (\(pool.allocations) allocated, \(pool.liveBytes) B)")
        if let lifecycleLine {
            lines.append(lifecycleLine)
        }
        if let settledLine {
            lines.append(settledLine)
        }
        return lines
    }

    private static func milliseconds(_ distribution: RenderMetrics.Distribution) -> String {
        [distribution.p50, distribution.p95, distribution.p99]
            .map { String(format: "%.3f", milliseconds($0)) }
            .joined(separator: "/")
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    // MARK: Diagnostics

    private func updateDiagnostics() {
        let tint = NativeTint(rawValue: tintControl.selectedSegmentIndex) ?? .none
        let motion: String = switch (mode, updateLink?.isEnabled == true) {
        case (.pattern, _): "still pattern"
        case (.moving, true): "running"
        case (.moving, false):
            if !wantsMotion { "paused" } else if accessibilitySettings.reduceMotion { "paused (Reduce Motion)" } else { "paused (hidden)" }
        }
        var lines = [
            Self.gpuDescription,
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
            let settings = surface.accessibilitySettings
            if let presented = surface.presentedPanel?.parameters.tint {
                let surfaceKind = settings.reduceTransparency ? "opaque (Reduce Transparency)" : "glass"
                let contrast = presented.worstCaseContrast(againstTextLuminance: panelTextLuminance)
                lines.append("Panel: \(surfaceKind) · tint \(String(format: "%.2f", presented.strength)) · text contrast ≥ \(String(format: "%.1f", contrast)):1 (target \(String(format: "%.1f", panelContrastTarget)))")
            }
            if let labGlow, let glow = surface.presentedPanel?.parameters.glow {
                lines.append("Glow: \(labGlow.rawValue) · \(glow.colors.count) colors · rim \(String(format: "%.1f", glow.rimWidth)) pt · inner \(String(format: "%.2f", glow.innerGlowIntensity)) · center \(String(format: "%.2f", glow.centerOpacity))")
                let pulse = glow.pulseDepth > 0
                    ? "pulse \(String(format: "%.1f", glow.pulsePeriod)) s × \(String(format: "%.2f", glow.pulseDepth))"
                    : "no pulse"
                lines.append("Halo: \(String(format: "%.0f", glow.hasHalo ? glow.haloRadius : 0)) pt · \(String(format: "%.2f", glow.hasHalo ? glow.haloIntensity : 0)) · \(pulse) · effect clock \(surface.isAnimating ? "running" : "stopped") · t \(String(format: "%.2f", surface.renderer.effectTime)) s")
            }
            if let labInterior, let interior = surface.presentedPanel?.parameters.interior {
                let drawn = interior.isVisible
                    ? "\(interior.colors.count) colors · intensity \(String(format: "%.2f", interior.intensity)) · speed \(String(format: "%.2f", interior.speed)) · seed \(interior.seed) · fade \(String(format: "%.2f", interior.centerFade))"
                    : "not drawn"
                lines.append("Interior: \(labInterior.rawValue) · \(drawn) · effect clock \(surface.isAnimating ? "running" : "stopped") · t \(String(format: "%.2f", surface.renderer.effectTime)) s")
            }
            if let labNativeGlow {
                let glow = nativeHost.presentedGlow
                let pulse = glow.pulseDepth > 0
                    ? "pulse \(String(format: "%.1f", glow.pulsePeriod)) s × \(String(format: "%.2f", glow.pulseDepth))"
                    : "no pulse"
                lines.append("Native glow: \(nativeGlowSwitch.isOn ? labNativeGlow.rawValue : "off") · \(glow.colors.count) colors · rim \(String(format: "%.1f", glow.rimWidth)) pt · halo \(String(format: "%.0f", glow.hasHalo ? glow.haloRadius : 0)) pt · \(String(format: "%.2f", glow.hasHalo ? glow.haloIntensity : 0)) · \(pulse) · animation \(nativeHost.isAnimating ? "running" : "stopped")")
            }
            lines.append("Accessibility: Reduce Motion \(settings.reduceMotion ? "on" : "off") · Reduce Transparency \(settings.reduceTransparency ? "on" : "off") · contrast \(traitCollection.accessibilityContrast == .high ? "high" : "normal") · \(traitCollection.userInterfaceStyle == .dark ? "dark" : "light") · text \(traitCollection.preferredContentSizeCategory.rawValue.replacingOccurrences(of: "UICTContentSizeCategory", with: ""))")
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
        if let benchmark {
            lines.append(contentsOf: benchmarkDiagnostics(benchmark))
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

    /// The GPU line never changes, so it is computed once.
    private static let gpuDescription: String = makeGPUDescription()

    private static func makeGPUDescription() -> String {
        guard let device = MTLCreateSystemDefaultDevice() else { return "No Metal device" }
        let capabilities = RenderCapabilities(device: device)
        let family = capabilities.highestAppleFamily.map { "apple\($0)" } ?? "none"
        return "GPU \(capabilities.deviceName) · Metal 3 \(capabilities.supportsMetal3) · Metal 4 \(capabilities.supportsMetal4) · \(family)"
    }
}

/// Scrolling the stage moves the native panel content; the glass panel
/// follows it.
extension LabViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateCustomPanel()
    }
}

/// The stage (and the scrolling content host inside it) reports each layout
/// pass after its subviews have frames, so the
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
