import GlassWeave
import GlassWeaveUIKit
import Metal
import UIKit

/// The glow gallery (GW-20): original demos of the glow work on one glass
/// surface, with native controls on top.
///
/// - A light/dark switch (``ThemeToggle``): a round glass knob with a warm
///   rim light on its top edge and a soft halo, over a recessed track in the
///   background. Switching changes the gallery's appearance
///   (`overrideUserInterfaceStyle`): the knob slides and the background and
///   text cross-dissolve; under Reduce Motion the knob moves at once and only
///   the cross-dissolve remains.
/// - Three element capsules (``ElementCard``), dark glass with their own
///   edge colors over a dark stage with a faint floor reflection. Selecting
///   one brightens it (a stronger rim, a deep inner glow, a faint two-color
///   fill, a wide halo) and runs its interior; the others stay calm, with a
///   clear middle. Selecting it again deselects it.
/// - An energy orb on a dark bar, a native button: charging it makes the orb
///   surge for a few seconds (a moving energy interior, a pulse, a wide
///   halo) and then settle.
/// - Genuine native glass with a GW-14 rim and halo, for comparison.
///
/// All custom glass is drawn by one `GlassSurfaceView` in one pass
/// (`setPanels`), over one background frame the gallery produces only when
/// what it shows changes (``GalleryBackdrop``). The shapes are laid out so
/// that no two panels' quads (shape, halo, and one pixel) overlap; the
/// diagnostics say whether they do. Nothing animates at rest: the surface's
/// effect clock runs only while a selected capsule's interior or the
/// surging orb moves, and the gallery's own transition link runs only while
/// a switch, selection, or surge is changing, so a settled gallery submits
/// no frames.
final class GlowGalleryViewController: UIViewController {
    /// How long the orb surges after one charge, in seconds.
    static let surgeDuration: Duration = .seconds(5)

    private struct Rendering {
        let surface: GlassSurfaceView
        let background: GalleryBackground
    }

    /// The animated levels: each moves toward its target while the
    /// transition link runs. Values are linear progress, 0...1; the style
    /// applies an ease.
    private struct Levels: Equatable {
        var theme = 0.0
        var knob = 0.0
        var capsules = [0.0, 0.0, 0.0]
        var orb = 0.0
    }

    private var rendering: Result<Rendering, any Error>?
    /// What the next background frame shows, and what the frame on screen
    /// shows.
    private var backdrop = GalleryBackdrop()
    private var producedBackdrop: GalleryBackdrop?

    // MARK: Content

    private let scroll = UIScrollView()
    private let contentHost = StageView()
    private let content = UIStackView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(configuration: .glass())
    private let themeCaption = UILabel()
    private let themeToggle = ThemeToggle()
    private let themeRow = UIStackView()
    private let stage = UIView()
    private let elementsRow = UIStackView()
    private let cards = GalleryElement.allCases.map { ElementCard(element: $0) }
    private let orbButton = UIButton(configuration: .plain())
    /// Where the orb's glass is drawn, inside the orb button.
    private let orb = UIView()
    private let nativeHost = EnhancedNativeGlassView()
    private let nativeButton = UIButton(configuration: .plain())
    private let nativeCaption = UILabel()
    private let diagnosticsLabel = UILabel()
    private var stageRowTop: NSLayoutConstraint?

    /// How long text and native content take to cross-dissolve to the other
    /// appearance, in seconds.
    static let themeCrossDissolve = 0.35
    static let orbDiameter: CGFloat = 68
    /// Space between the bar's edge and the orb: its widest halo stays on the
    /// dark bar.
    static let orbMargin = CGFloat(GalleryStyle.orbSurgeHalo + 2)
    /// Space between capsules: a selected capsule's halo, a calm
    /// neighbour's halo, and two points, which cover the pixel each quad
    /// reaches past its halo, so their quads never overlap. While the
    /// selection moves, one halo shrinks as fast as the other grows.
    static let capsuleGap = CGFloat(GalleryStyle.capsuleSelectedHalo + GalleryStyle.capsuleCalmHalo + 2)
    /// Space between the stage's sides and the capsules: a selected
    /// capsule's halo stays on the dark stage, where light shows.
    static let stageInset = CGFloat(GalleryStyle.capsuleSelectedHalo)

    // MARK: State

    private var selected: GalleryElement?
    private var charges = 0
    private var nativeTaps = 0
    private var surge: Task<Void, Never>?
    private var levels = Levels()
    private var targets = Levels()
    private var transitionLink: UIUpdateLink?
    private var lastLinkTime: Double?
    /// Until the switch is used, the gallery follows the window's appearance.
    private var themeIsChosen = false
    private var appliedLaunchState = false
    private weak var observedScene: UIWindowScene?
    private var sceneObservations: [NotificationCenter.ObservationToken] = []
    private var submittedWhenHidden: Int?
    private var hiddenPeriodSubmissions: Int?
    private var quadsApart = true

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        if UserDefaults.standard.bool(forKey: "lab.increaseContrast") {
            // Stands in for the system setting in UI tests: the surface's
            // policy and every system color read it from the traits.
            traitOverrides.accessibilityContrast = .high
        }
        setUpRendering()
        setUpContent()
        applyContentSizeLayout()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.applyContentSizeLayout()
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (self: Self, _) in
            self.followWindowAppearance()
            self.updateDiagnostics()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        observeScene()
        followWindowAppearance()
        applyLaunchState()
        updateGeometry()
        updateDiagnostics()
    }

    /// Refreshes the diagnostics when this window's scene activates or
    /// deactivates, which changes no frame by itself.
    private func observeScene() {
        guard let scene = view.window?.windowScene, scene !== observedScene else { return }
        observedScene = scene
        let center = NotificationCenter.default
        let subject: UIScene = scene
        sceneObservations = [
            center.addObserver(of: subject, for: UIScene.DidActivateMessage.self) { [weak self] _ in
                self?.updateDiagnostics()
            },
            center.addObserver(of: subject, for: UIScene.WillDeactivateMessage.self) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateDiagnostics() }
            },
        ]
    }

    /// `-lab.gallerySelect <element>` selects a capsule and
    /// `-lab.galleryCharge YES` charges the orb once, when the gallery first
    /// appears, for captures and comparison runs.
    private func applyLaunchState() {
        guard !appliedLaunchState else { return }
        appliedLaunchState = true
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: "lab.gallerySelect"),
           let element = GalleryElement.allCases.first(where: { $0.identifier == name }) {
            elementTapped(element)
        }
        if defaults.bool(forKey: "lab.galleryCharge") {
            chargeOrb()
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        layoutCapsules()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Lay the scrolling content out now, so the glass copies its final
        // frames.
        scroll.layoutIfNeeded()
        updateGeometry()
    }

    /// Before the switch is first used, the gallery shows the appearance its
    /// window has, with the switch and the background to match.
    private func followWindowAppearance() {
        guard !themeIsChosen else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        themeToggle.setOn(dark)
        let value = dark ? 1.0 : 0
        levels.theme = value
        levels.knob = value
        targets.theme = value
        targets.knob = value
        themeToggle.knobPosition = value
        updateGeometry()
    }

    // MARK: Rendering setup

    private func setUpRendering() {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw GalleryFailure.noMetalDevice }
            guard let queue = device.makeCommandQueue() else { throw GalleryFailure.noCommandQueue }
            queue.label = "GlassWeaveLab gallery"
            let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
            surface.accessibilityIdentifier = "gallery.surface"
            surface.translatesAutoresizingMaskIntoConstraints = false
            if let override = LabViewController.accessibilitySettingsOverride {
                surface.accessibilitySettingsSource = .fixed(override)
            }
            view.addSubview(surface)
            NSLayoutConstraint.activate([
                surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                surface.topAnchor.constraint(equalTo: view.topAnchor),
                surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            let background = try GalleryBackground(device: device)
            rendering = .success(Rendering(surface: surface, background: background))
            surface.renderObserver = { [weak self] _ in self?.renderDidFinish() }
            surface.visibilityHandler = { [weak self] visible in self?.surfaceVisibilityChanged(visible) }
            surface.accessibilitySettingsHandler = { [weak self] _ in
                self?.updateGeometry()
                self?.updateDiagnostics()
            }
            surface.setFrameProducer { [weak self] commandBuffer, pixelSize in
                self?.produceBackground(into: commandBuffer, pixelSize: pixelSize)
            }
        } catch {
            rendering = .failure(error)
        }
    }

    private enum GalleryFailure: Error, CustomStringConvertible {
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
    /// already shows it (the surface then draws that frame again).
    private func produceBackground(into commandBuffer: any MTLCommandBuffer, pixelSize: (width: Int, height: Int)) -> BackgroundFrameLease? {
        guard case let .success(rendering) = rendering else { return nil }
        var next = backdrop
        next.pixelWidth = pixelSize.width
        next.pixelHeight = pixelSize.height
        if next == producedBackdrop, rendering.surface.renderer.currentFrame != nil {
            return nil
        }
        guard let lease = rendering.background.encodeFrame(into: commandBuffer, backdrop: next) else { return nil }
        producedBackdrop = next
        return lease
    }

    // MARK: Content setup

    private func setUpContent() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.accessibilityIdentifier = "gallery.scroll"
        // The scroll view insets its content by the safe area; the glass
        // behind it fills the whole screen.
        scroll.contentInsetAdjustmentBehavior = .always
        scroll.delegate = self
        view.addSubview(scroll)
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.onLayout = { [weak self] in self?.updateGeometry() }
        scroll.addSubview(contentHost)
        content.axis = .vertical
        content.spacing = 22
        content.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(content)

        // Title and close.
        titleLabel.text = String(localized: "Glow gallery")
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits.insert(.header)
        closeButton.configuration?.title = String(localized: "Close")
        closeButton.accessibilityIdentifier = "gallery.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleRow = UIStackView(arrangedSubviews: [titleLabel, closeButton])
        titleRow.alignment = .center
        titleRow.spacing = 12

        // Appearance switch, with a caption that it carries for VoiceOver.
        themeCaption.text = String(localized: "Dark appearance")
        themeCaption.font = .preferredFont(forTextStyle: .headline)
        themeCaption.adjustsFontForContentSizeCategory = true
        themeCaption.numberOfLines = 0
        themeCaption.isAccessibilityElement = false
        themeToggle.addAction(UIAction { [weak self] _ in self?.themeToggled() }, for: .valueChanged)
        themeToggle.setContentHuggingPriority(.required, for: .horizontal)
        themeToggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        themeRow.addArrangedSubview(themeCaption)
        themeRow.addArrangedSubview(themeToggle)
        themeRow.spacing = 16

        // Elements on their dark stage.
        for card in cards {
            card.addAction(UIAction { [weak self, element = card.element] _ in self?.elementTapped(element) }, for: .primaryActionTriggered)
        }
        cards.forEach(elementsRow.addArrangedSubview)
        elementsRow.alignment = .top
        elementsRow.spacing = Self.capsuleGap
        elementsRow.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(elementsRow)
        stage.accessibilityIdentifier = "gallery.stage"
        let rowTop = elementsRow.topAnchor.constraint(equalTo: stage.topAnchor, constant: 38)
        stageRowTop = rowTop
        NSLayoutConstraint.activate([
            rowTop,
            elementsRow.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -18),
            elementsRow.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            elementsRow.leadingAnchor.constraint(greaterThanOrEqualTo: stage.leadingAnchor, constant: Self.stageInset),
        ])

        // The energy orb: a native button on a dark bar, the orb's glass at
        // its leading end.
        var orbConfiguration = UIButton.Configuration.plain()
        orbConfiguration.title = String(localized: "Charge the orb")
        orbConfiguration.subtitle = String(localized: "Resting")
        orbConfiguration.titleAlignment = .leading
        orbConfiguration.baseForegroundColor = .white
        orbConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .headline)
            return attributes
        }
        orbConfiguration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .subheadline)
            attributes.foregroundColor = UIColor(white: 1, alpha: 0.82)
            return attributes
        }
        orbConfiguration.contentInsets = NSDirectionalEdgeInsets(
            top: 18, leading: Self.orbDiameter + 2 * Self.orbMargin - 6, bottom: 18, trailing: 20
        )
        orbButton.configuration = orbConfiguration
        orbButton.contentHorizontalAlignment = .leading
        orbButton.accessibilityIdentifier = "gallery.orb"
        orbButton.addAction(UIAction { [weak self] _ in self?.chargeOrb() }, for: .primaryActionTriggered)
        orb.isUserInteractionEnabled = false
        orb.isAccessibilityElement = false
        orb.translatesAutoresizingMaskIntoConstraints = false
        orbButton.addSubview(orb)
        NSLayoutConstraint.activate([
            orb.widthAnchor.constraint(equalToConstant: Self.orbDiameter),
            orb.heightAnchor.constraint(equalToConstant: Self.orbDiameter),
            orb.leadingAnchor.constraint(equalTo: orbButton.leadingAnchor, constant: Self.orbMargin),
            orb.centerYAnchor.constraint(equalTo: orbButton.centerYAnchor),
            orbButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.orbDiameter + 2 * Self.orbMargin),
        ])

        // Native glass with a GW-14 glow, for comparison.
        nativeButton.configuration?.title = String(localized: "Native glass")
        nativeButton.configuration?.baseForegroundColor = .label
        nativeButton.accessibilityIdentifier = "gallery.nativeButton"
        nativeButton.translatesAutoresizingMaskIntoConstraints = false
        nativeButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            nativeTaps += 1
            updateDiagnostics()
        }, for: .primaryActionTriggered)
        nativeHost.glass.cornerConfiguration = .capsule()
        nativeHost.glass.configuration = NativeGlassView.Configuration(isInteractive: true)
        nativeHost.glass.contentView.addSubview(nativeButton)
        if let override = LabViewController.accessibilitySettingsOverride {
            nativeHost.accessibilitySettingsSource = .fixed(override)
        }
        NSLayoutConstraint.activate([
            nativeButton.leadingAnchor.constraint(equalTo: nativeHost.glass.contentView.leadingAnchor, constant: 22),
            nativeButton.trailingAnchor.constraint(equalTo: nativeHost.glass.contentView.trailingAnchor, constant: -22),
            nativeButton.topAnchor.constraint(equalTo: nativeHost.glass.contentView.topAnchor, constant: 3),
            nativeButton.bottomAnchor.constraint(equalTo: nativeHost.glass.contentView.bottomAnchor, constant: -3),
            nativeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        nativeCaption.text = String(localized: "Apple's glass with a GlassWeave rim and halo")
        nativeCaption.font = .preferredFont(forTextStyle: .footnote)
        nativeCaption.adjustsFontForContentSizeCategory = true
        nativeCaption.numberOfLines = 0
        nativeCaption.textAlignment = .center
        let nativeColumn = UIStackView(arrangedSubviews: [nativeHost, nativeCaption])
        nativeColumn.axis = .vertical
        nativeColumn.alignment = .center
        nativeColumn.spacing = 12 + CGFloat(GalleryStyle.nativeGlow(for: nil).haloRadius)
        updateNativeGlow()

        diagnosticsLabel.font = .preferredFont(forTextStyle: .caption1)
        diagnosticsLabel.adjustsFontForContentSizeCategory = true
        diagnosticsLabel.numberOfLines = 0
        diagnosticsLabel.textColor = .secondaryLabel
        diagnosticsLabel.accessibilityIdentifier = "gallery.diagnostics"

        content.addArrangedSubview(titleRow)
        content.addArrangedSubview(themeRow)
        content.addArrangedSubview(Self.sectionHeader(String(localized: "Elements")))
        content.addArrangedSubview(stage)
        content.addArrangedSubview(Self.sectionHeader(String(localized: "Energy orb")))
        content.addArrangedSubview(orbButton)
        content.addArrangedSubview(Self.sectionHeader(String(localized: "Native glass")))
        content.addArrangedSubview(nativeColumn)
        content.addArrangedSubview(diagnosticsLabel)
        content.setCustomSpacing(10, after: content.arrangedSubviews[2])
        content.setCustomSpacing(10, after: content.arrangedSubviews[4])
        content.setCustomSpacing(18 + CGFloat(GalleryStyle.nativeGlow(for: nil).haloRadius), after: content.arrangedSubviews[6])
        content.setCustomSpacing(32, after: nativeColumn)

        let frame = scroll.frameLayoutGuide
        // 600 points wide where the window allows, otherwise its full width
        // less the margins: above every arranged subview's hugging.
        let readable = content.widthAnchor.constraint(equalToConstant: 600)
        readable.priority = .required - 1
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentHost.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            contentHost.widthAnchor.constraint(equalTo: frame.widthAnchor),
            content.topAnchor.constraint(equalTo: contentHost.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor, constant: -16),
            content.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            readable,
        ])
    }

    /// A section title. It hugs its text (a spacer takes the rest of the
    /// row), so its frame, which VoiceOver outlines, is the text's.
    private static func sectionHeader(_ text: String) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .title3)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.accessibilityTraits.insert(.header)
        let spacer = UIView()
        spacer.isAccessibilityElement = false
        spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [label, spacer])
        row.axis = .horizontal
        return row
    }

    /// At accessibility text sizes the rows stack vertically and each
    /// capsule's name sits beside it, so no text is cut off.
    private func applyContentSizeLayout() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        themeRow.axis = large ? .vertical : .horizontal
        themeRow.alignment = large ? .leading : .center
        elementsRow.axis = large ? .vertical : .horizontal
        elementsRow.alignment = large ? .leading : .top
        cards.forEach { $0.setCompact(large) }
        view.setNeedsLayout()
    }

    /// Sizes the capsules from the stage's width: three in a row with the
    /// gap between them, at most 96 points wide, 1.6 times as tall.
    private func layoutCapsules() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        // The content's width, from local bounds: 600 points, or the safe
        // area less the margins.
        let available = min(600, view.bounds.inset(by: view.safeAreaInsets).width - 32)
        let width: CGFloat = large ? 72 : min(max(((available - 2 * Self.stageInset - 2 * Self.capsuleGap) / 3).rounded(.down), 56), 96)
        let size = CGSize(width: width, height: (width * 1.6).rounded())
        cards.forEach { $0.setCapsuleSize(size) }
    }

    // MARK: Actions

    private func themeToggled() {
        themeIsChosen = true
        let dark = themeToggle.isOn
        // Text and native content cross-dissolve to the new appearance.
        UIView.transition(with: scroll, duration: Self.themeCrossDissolve, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.overrideUserInterfaceStyle = dark ? .dark : .light
        }
        targets.theme = dark ? 1 : 0
        targets.knob = dark ? 1 : 0
        if reduceMotion {
            // No slide; the background still cross-dissolves.
            levels.knob = targets.knob
        }
        startTransition()
    }

    private func elementTapped(_ element: GalleryElement) {
        selected = selected == element ? nil : element
        for card in cards {
            card.isSelected = card.element == selected
        }
        for index in targets.capsules.indices {
            targets.capsules[index] = GalleryElement(rawValue: index) == selected ? 1 : 0
        }
        if reduceMotion {
            levels.capsules = targets.capsules
        }
        updateNativeGlow()
        startTransition()
    }

    /// One charge: the orb surges for ``surgeDuration``, then settles. A
    /// charge during a surge restarts its time.
    private func chargeOrb() {
        charges += 1
        targets.orb = 1
        if reduceMotion { levels.orb = 1 }
        updateOrbLabel()
        startTransition()
        surge?.cancel()
        surge = Task { [weak self] in
            try? await Task.sleep(for: Self.surgeDuration)
            guard !Task.isCancelled, let self else { return }
            targets.orb = 0
            if reduceMotion { levels.orb = 0 }
            updateOrbLabel()
            startTransition()
        }
    }

    private func updateOrbLabel() {
        let surging = targets.orb > 0
        orbButton.configuration?.subtitle = surging ? String(localized: "Surging") : String(localized: "Resting")
    }

    private func updateNativeGlow() {
        // The glow is finite, so the view never rejects it.
        try? nativeHost.setGlow(GalleryStyle.nativeGlow(for: selected))
    }

    private var reduceMotion: Bool {
        if case let .success(rendering) = rendering {
            return rendering.surface.accessibilitySettings.reduceMotion
        }
        return UIAccessibility.isReduceMotionEnabled
    }

    // MARK: Transitions

    /// Runs the transition link until every level reaches its target.
    private func startTransition() {
        updateGeometry()
        defer { updateDiagnostics() }
        guard levels != targets, transitionLink == nil else { return }
        let link = UIUpdateLink(view: view) { [weak self] _, info in
            self?.transitionTick(modelTime: info.modelTime)
        }
        link.requiresContinuousUpdates = true
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.isEnabled = true
        lastLinkTime = nil
        transitionLink = link
    }

    private func transitionTick(modelTime: Double) {
        guard transitionLink != nil else { return }
        let step = lastLinkTime.map { min(max(modelTime - $0, 0), 0.1) } ?? 0
        lastLinkTime = modelTime
        func approach(_ value: inout Double, _ target: Double, duration: Double) {
            let delta = step / duration
            value = value < target ? min(value + delta, target) : max(value - delta, target)
        }
        // Under Reduce Motion the background cross-dissolves with the text
        // (``themeCrossDissolve``); otherwise it follows the sliding knob.
        approach(&levels.theme, targets.theme, duration: reduceMotion ? Self.themeCrossDissolve : 0.45)
        approach(&levels.knob, targets.knob, duration: 0.45)
        for index in levels.capsules.indices {
            approach(&levels.capsules[index], targets.capsules[index], duration: 0.35)
        }
        approach(&levels.orb, targets.orb, duration: targets.orb > levels.orb ? 0.5 : 0.8)
        updateGeometry()
        if levels == targets {
            transitionLink?.isEnabled = false
            transitionLink = nil
            updateDiagnostics()
        }
    }

    /// Smoothstep: eases in and out of every transition.
    private static func ease(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: Geometry

    /// Places every glass panel at its native placeholder's frame, in the
    /// surface's points, and describes the background to match. Called after
    /// layout, on scroll, and on every transition step.
    private func updateGeometry() {
        guard case let .success(rendering) = rendering else { return }
        let surface = rendering.surface
        guard surface.bounds.width > 0 else { return }
        themeToggle.knobPosition = Self.ease(levels.knob)
        themeToggle.layoutIfNeeded()
        let theme = Self.ease(levels.theme)
        let knob = themeToggle.convert(themeToggle.knobFrame, to: surface)
        var panels = [GlassPanel(frame: knob, parameters: GalleryStyle.knob(diameter: knob.width, theme: theme))]
        var capsules: [GalleryBackdrop.Capsule] = []
        for (index, card) in cards.enumerated() {
            let rect = card.capsule.convert(card.capsule.bounds, to: surface)
            let level = Self.ease(levels.capsules[index])
            panels.append(GlassPanel(frame: rect, parameters: GalleryStyle.capsule(card.element, width: rect.width, level: level)))
            let edge = card.element.edgeColor
            capsules.append(.init(rect: rect, red: edge.red, green: edge.green, blue: edge.blue, reflection: 0.3 + 0.5 * level))
        }
        let orbRect = orb.convert(orb.bounds, to: surface)
        panels.append(GlassPanel(frame: orbRect, parameters: GalleryStyle.orb(diameter: orbRect.width, level: Self.ease(levels.orb))))
        do {
            try surface.setPanels(panels)
        } catch {
            self.rendering = .failure(error)
            return
        }
        quadsApart = Self.quadsAreApart(surface.presentedPanels, pixel: 1 / max(surface.traitCollection.displayScale, 1))

        var next = GalleryBackdrop()
        next.displayScale = Double(surface.traitCollection.displayScale)
        next.theme = theme
        next.size = surface.bounds.size
        next.track = themeToggle.convert(themeToggle.bounds, to: surface)
        next.stage = stage.convert(stage.bounds, to: surface)
        next.bar = orbButton.convert(orbButton.bounds, to: surface)
        next.capsules = capsules
        next.showsReflections = !surface.accessibilitySettings.reduceTransparency
        if next != backdrop {
            backdrop = next
            surface.requestFrame()
        }
    }

    /// Whether no two panels' quads (the panel grown by its halo and one
    /// pixel, `pixel` points, on every side) overlap; where they would, the
    /// later panel would cut into the earlier one's halo.
    private static func quadsAreApart(_ panels: [GlassPanel], pixel: CGFloat) -> Bool {
        let quads = panels.map { panel -> CGRect in
            let glow = panel.parameters.glow
            let reach = CGFloat(glow.hasHalo ? glow.haloRadius : 0) + pixel
            return panel.frame.insetBy(dx: -reach, dy: -reach)
        }
        for (index, quad) in quads.enumerated() {
            for other in quads[(index + 1)...] where quad.intersects(other) {
                return false
            }
        }
        return true
    }

    // MARK: Visibility and diagnostics

    private func surfaceVisibilityChanged(_ visible: Bool) {
        guard case let .success(rendering) = rendering else { return }
        let submitted = rendering.surface.frameStatistics.submitted
        if visible {
            if let submittedWhenHidden {
                hiddenPeriodSubmissions = submitted - submittedWhenHidden
            }
            submittedWhenHidden = nil
        } else {
            submittedWhenHidden = submitted
            rendering.background.trim()
        }
        updateDiagnostics()
    }

    /// While something animates, the diagnostics refresh about four times a
    /// second; otherwise after every draw.
    private func renderDidFinish() {
        guard case let .success(rendering) = rendering else { return }
        let animating = rendering.surface.isAnimating || transitionLink != nil
        if !animating || rendering.surface.frameStatistics.submitted % 15 == 0 {
            updateDiagnostics()
        }
    }

    private func updateDiagnostics() {
        guard isViewLoaded else { return }
        let orbState = targets.orb > 0 ? "surging" : (levels.orb > 0 ? "settling" : "resting")
        orbButton.accessibilityValue = targets.orb > 0 ? String(localized: "Surging") : String(localized: "Resting")
        var lines = [
            "Gallery: appearance \(traitCollection.userInterfaceStyle == .dark ? "dark" : "light") · selected \(selected?.identifier ?? "none") · orb \(orbState) · charges \(charges) · native taps \(nativeTaps)",
        ]
        switch rendering {
        case let .success(rendering):
            let surface = rendering.surface
            let presented = surface.presentedPanels
            let halos = presented.count(where: { $0.parameters.glow.hasHalo })
            let interiors = presented.count(where: { $0.parameters.interior.isVisible })
            let moving = presented.count(where: { $0.parameters.glow.isAnimated || $0.parameters.interior.isAnimated })
            lines.append("Glass: \(presented.count) panels · \(halos) halos · \(interiors) interiors · \(moving) moving · quads \(quadsApart ? "apart" : "overlap") · effect clock \(surface.isAnimating ? "running" : "stopped") · transition \(transitionLink != nil ? "running" : "idle")")
            lines.append("Background: \(rendering.background.producedCount) frames produced")
            let settings = surface.accessibilitySettings
            lines.append("Accessibility: Reduce Motion \(settings.reduceMotion ? "on" : "off") · Reduce Transparency \(settings.reduceTransparency ? "on" : "off") · contrast \(traitCollection.accessibilityContrast == .high ? "high" : "normal") · \(traitCollection.userInterfaceStyle == .dark ? "dark" : "light") · text \(traitCollection.preferredContentSizeCategory.rawValue.replacingOccurrences(of: "UICTContentSizeCategory", with: ""))")
            let statistics = surface.frameStatistics
            lines.append("Surface: \(surface.isVisible ? "visible" : "hidden") · scene \(Self.describe(view.window?.windowScene?.activationState))")
            lines.append("Frames: \(statistics.submitted) submitted · \(statistics.framesInFlight) in flight (peak \(statistics.peakFramesInFlight) of \(GlassSurfaceView.maximumFramesInFlight)) · \(statistics.deferredWhileHidden) deferred hidden · \(statistics.deferredAtLimit) at limit · \(statistics.coalesced) coalesced")
            if let hiddenPeriodSubmissions {
                lines.append("Last hidden period: \(hiddenPeriodSubmissions) submitted")
            }
        case let .failure(error):
            lines.append("Gallery unavailable: \(error)")
        case nil:
            break
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
}

/// Scrolling moves the native content; the glass follows it.
extension GlowGalleryViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateGeometry()
    }
}
