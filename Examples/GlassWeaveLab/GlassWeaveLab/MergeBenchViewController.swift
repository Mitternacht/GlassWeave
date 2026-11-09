import GlassWeave
import GlassWeaveUIKit
import Metal
import UIKit

/// The merge page (GW-13): two of GlassWeave's own glass surfaces that merge
/// into one pill and separate again, beside Apple's own merge.
///
/// - **Top group: GlassWeave glass, custom to custom.** A minus and a plus
///   button, each on a round surface of glass. Both surfaces are two parts of
///   one blob, drawn as **one** panel, so the lens, the light and the shadow
///   follow the merged outline with no seam. A native switch merges them (a
///   critically damped spring on the surface's effect clock), a native button
///   reverses the flight at any moment without a jump, and a native slider
///   scrubs the progress by hand. The native buttons keep their own frames and
///   hit testing the whole time: the glass is decorative, and the value between
///   the buttons fades in with ordinary UIKit animation.
/// - **Bottom group: `UIGlassEffect` in a `UIGlassContainerEffect`.** The same
///   two shapes in Apple's glass, merged by the system's container: a separate
///   material system, driven from the same progress.
/// - **Status line.** Progress, target and velocity of the spring, whether the
///   effect clock runs, the surface's submitted frames and the submissions since
///   the spring settled (it must stay at +0: the page draws on demand again).
///
/// `-lab.merge YES` opens it; `-lab.mergeBackdrop stage|orbs` picks the backdrop
/// (default stage, the dark page); `-lab.merge.progress <0...1>` pins the
/// progress (no spring, no clock) for captures; `-lab.merge.auto YES` merges
/// once, reverses in flight and lets it settle apart, to show the interrupt and
/// the settle.
final class MergeBenchViewController: UIViewController {
    private enum Backdrop: Int, CaseIterable {
        case stage, orbs

        var page: BenchPage {
            switch self {
            case .stage: .stage
            case .orbs: .orbs
            }
        }
        var title: String {
            switch self {
            case .stage: String(localized: "Stage")
            case .orbs: String(localized: "Orbs")
            }
        }
        var identifier: String {
            switch self {
            case .stage: "stage"
            case .orbs: "orbs"
            }
        }
    }

    private struct Rendering {
        let surface: GlassSurfaceView
        let background: BenchBackground
    }

    /// The glass of the stepper, in points from the center of its frame: two
    /// round surfaces 104 pt apart that reach for each other and end as one
    /// pill. The buttons stay at the two centers. Each surface ends as an arm
    /// that reaches past the middle, so the two arms overlap and the pill is
    /// one exact stadium (no notch, no seam) from the progress at which they
    /// overlap on (`neckEnd`); the neck before that is rounded by a wide blend.
    private static let stepperSize = CGSize(width: 168, height: 64)
    private static let buttonOffset: CGFloat = 52
    private static let merge: GlassSurfaceMerge = {
        let size = stepperSize
        let left = CGPoint(x: -buttonOffset, y: 0), right = CGPoint(x: buttonOffset, y: 0)
        let reachLeft = CGPoint(x: 22, y: 0), reachRight = CGPoint(x: -22, y: 0)
        return GlassSurfaceMerge(
            first: .init(
                separate: .circle(center: left, radius: 28, in: size),
                merged: .capsule(from: left, to: reachLeft, radius: 32, in: size)
            ),
            second: .init(
                separate: .circle(center: right, radius: 28, in: size),
                merged: .capsule(from: right, to: reachRight, radius: 32, in: size)
            ),
            smoothness: 0.35, interiorSmoothness: 0.9, neckEnd: 0.7
        )
    }()

    private var rendering: Result<Rendering, any Error>?
    private var producedKey: String?
    private var backdrop: Backdrop
    private var transition: SurfaceTransition?
    private let pinnedProgress: Double?
    private let autoRun: Bool

    private let titleLabel = UILabel()
    private let closeButton = UIButton(configuration: .glass())
    private let headlineLabel = UILabel()
    private let bodyLabel = UILabel()
    private let weaveCaption = UILabel()
    private let nativeCaption = UILabel()
    private let valueLabel = UILabel()
    private let mergeSwitch = UISwitch()
    private let switchLabel = UILabel()
    private let reverseButton = UIButton(configuration: .glass())
    private let progressSlider = UISlider()
    private let backdropControl = UISegmentedControl(items: Backdrop.allCases.map(\.title))
    private let statusLabel = UILabel()
    private let minusButton = UIButton(configuration: .plain())
    private let plusButton = UIButton(configuration: .plain())
    private let nativeMinus = UIButton(configuration: .plain())
    private let nativePlus = UIButton(configuration: .plain())
    private let nativeContainer = UIVisualEffectView(effect: nil)
    private let nativeFirst = NativeGlassView(configuration: .init(isInteractive: true))
    private let nativeSecond = NativeGlassView(configuration: .init(isInteractive: true))
    private var weaveStepper = CGRect.zero
    private var nativeStepper = CGRect.zero

    private var quantity = 2
    private var submitted = 0
    private var settledMark: Int?
    private var statusTask: Task<Void, Never>?
    private var isScrubbing = false
    /// The spring's velocity at the last change, and the largest change of
    /// velocity between two consecutive ones. A reversal in flight keeps the
    /// velocity (the target changes, the state does not), so this stays near
    /// the spring's acceleration times one frame (about 3 per second at 60 Hz
    /// for the standard spring); a jump would flip it by twice the speed.
    private var lastVelocity: Double?
    private var largestVelocityChange = 0.0

    init() {
        let defaults = UserDefaults.standard
        backdrop = Backdrop.allCases.first { $0.identifier == defaults.string(forKey: "lab.mergeBackdrop") } ?? .stage
        pinnedProgress = defaults.object(forKey: "lab.merge.progress") == nil ? nil : defaults.double(forKey: "lab.merge.progress")
        autoRun = defaults.bool(forKey: "lab.merge.auto")
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Glass

    /// The page's glass: the refined, enhanced thick lens of the other pages,
    /// as one blob panel.
    private static func parameters() -> GlassParameters {
        RefinedLook.enhancedLens(corner: 999, bezel: 24, thickness: 26, dispersion: 0.4, dark: true)
    }

    /// The panel for a progress: the stepper frame with the merged outline.
    private func panels(for progress: Double) -> [GlassPanel] {
        var parameters = Self.parameters()
        parameters.shape = (try? Self.merge.shape(progress: progress)) ?? .roundedRectangle
        return [GlassPanel(frame: weaveStepper, parameters: parameters)]
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        if UserDefaults.standard.bool(forKey: "lab.increaseContrast") {
            traitOverrides.accessibilityContrast = .high
        }
        setUpRendering()
        setUpContent()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutContent()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard autoRun, transition != nil else { return }
        // Merge, turn around in flight, and settle apart: the page must then
        // read "after settle +0" and "clock off".
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.setMerged(true, animated: true)
            try? await Task.sleep(for: .seconds(0.22))
            self?.reverseTapped()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        statusTask?.cancel()
    }

    // MARK: Rendering

    private func setUpRendering() {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw BenchBackground.Failure.shaderUnavailable("no Metal device") }
            guard let queue = device.makeCommandQueue() else { throw BenchBackground.Failure.shaderUnavailable("no command queue") }
            queue.label = "GlassWeaveLab merge"
            let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
            surface.accessibilityIdentifier = "merge.surface"
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
            let background = try BenchBackground(device: device)
            rendering = .success(Rendering(surface: surface, background: background))
            surface.visibilityHandler = { [weak self] visible in
                if !visible { self?.currentBackground?.trim() }
            }
            surface.accessibilitySettingsHandler = { [weak self] _ in self?.scheduleStatus() }
            surface.renderObserver = { [weak self] outcome in
                guard let self else { return }
                if case .submitted = outcome { self.submitted += 1 }
                // The spring is over when it is not moving and the clock has
                // stopped: that frame is the last one, and any later
                // submission counts against the page.
                if let surface = self.surface, surface.isAnimating == false, self.transition?.isMoving != true {
                    self.settledMark = self.settledMark ?? self.submitted
                } else {
                    self.settledMark = nil
                }
                self.scheduleStatus()
            }
            surface.setFrameProducer { [weak self] commandBuffer, pixelSize in
                self?.produceBackground(into: commandBuffer, pixelSize: pixelSize)
            }
        } catch {
            rendering = .failure(error)
        }
    }

    private var currentBackground: BenchBackground? {
        if case let .success(rendering) = rendering { return rendering.background }
        return nil
    }

    private var surface: GlassSurfaceView? {
        if case let .success(rendering) = rendering { return rendering.surface }
        return nil
    }

    private func produceBackground(into commandBuffer: any MTLCommandBuffer, pixelSize: (width: Int, height: Int)) -> BackgroundFrameLease? {
        guard case let .success(rendering) = rendering else { return nil }
        let key = "\(backdrop.identifier) \(pixelSize.width)x\(pixelSize.height)"
        if key == producedKey, rendering.surface.renderer.currentFrame != nil { return nil }
        let scale = Double(traitCollection.displayScale)
        guard let lease = rendering.background.encodeFrame(into: commandBuffer, page: backdrop.page, pixelSize: pixelSize, scale: scale) else {
            return nil
        }
        producedKey = key
        return lease
    }

    // MARK: Content

    private func setUpContent() {
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.text = String(localized: "Merge")
        titleLabel.accessibilityTraits.insert(.header)
        closeButton.configuration?.title = String(localized: "Close")
        closeButton.accessibilityIdentifier = "merge.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)

        headlineLabel.font = .preferredFont(forTextStyle: .headline)
        headlineLabel.adjustsFontForContentSizeCategory = true
        headlineLabel.text = String(localized: "Quantity")
        headlineLabel.accessibilityTraits.insert(.header)
        bodyLabel.font = .preferredFont(forTextStyle: .footnote)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.numberOfLines = 0
        bodyLabel.text = String(localized: "Native text. Two surfaces of GlassWeave glass merge into one pill when you switch, and separate again.")
        weaveCaption.text = String(localized: "GlassWeave: custom to custom, one panel")
        nativeCaption.text = String(localized: "UIGlassEffect in a UIGlassContainerEffect: the system's own merge, a separate material system")
        for label in [weaveCaption, nativeCaption] {
            label.font = .preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "merge.status"

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        valueLabel.textAlignment = .center
        valueLabel.textColor = .white
        valueLabel.alpha = 0
        valueLabel.isAccessibilityElement = false
        valueLabel.accessibilityIdentifier = "merge.value"
        updateValue()

        switchLabel.font = .preferredFont(forTextStyle: .body)
        switchLabel.adjustsFontForContentSizeCategory = true
        switchLabel.text = String(localized: "Merged")
        mergeSwitch.accessibilityIdentifier = "merge.toggle"
        mergeSwitch.accessibilityLabel = String(localized: "Merged")
        mergeSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            setMerged(mergeSwitch.isOn, animated: true)
        }, for: .valueChanged)
        reverseButton.configuration?.title = String(localized: "Reverse")
        reverseButton.accessibilityIdentifier = "merge.reverse"
        reverseButton.addAction(UIAction { [weak self] _ in self?.reverseTapped() }, for: .primaryActionTriggered)
        progressSlider.minimumValue = 0
        progressSlider.maximumValue = 1
        progressSlider.accessibilityIdentifier = "merge.slider"
        progressSlider.accessibilityLabel = String(localized: "Merge progress")
        progressSlider.addAction(UIAction { [weak self] _ in self?.sliderMoved() }, for: .valueChanged)
        for event in [UIControl.Event.touchUpInside, .touchUpOutside, .touchCancel] {
            progressSlider.addAction(UIAction { [weak self] _ in self?.isScrubbing = false }, for: event)
        }
        backdropControl.selectedSegmentIndex = backdrop.rawValue
        backdropControl.accessibilityIdentifier = "merge.backdrop"
        backdropControl.addAction(UIAction { [weak self] _ in
            guard let self, let chosen = Backdrop(rawValue: backdropControl.selectedSegmentIndex) else { return }
            backdrop = chosen
            surface?.requestFrame()
        }, for: .valueChanged)

        configureButton(minusButton, symbol: "minus", label: String(localized: "Decrease"), identifier: "merge.weave.minus")
        configureButton(plusButton, symbol: "plus", label: String(localized: "Increase"), identifier: "merge.weave.plus")
        configureButton(nativeMinus, symbol: "minus", label: String(localized: "Decrease"), identifier: "merge.native.minus")
        configureButton(nativePlus, symbol: "plus", label: String(localized: "Increase"), identifier: "merge.native.plus")
        minusButton.addAction(UIAction { [weak self] _ in self?.step(-1) }, for: .primaryActionTriggered)
        plusButton.addAction(UIAction { [weak self] _ in self?.step(1) }, for: .primaryActionTriggered)

        // Apple's merge: two glass views in one container, which blends them
        // when they are closer than its spacing.
        let container = UIGlassContainerEffect()
        container.spacing = 40
        nativeContainer.effect = container
        nativeFirst.cornerConfiguration = .capsule()
        nativeSecond.cornerConfiguration = .capsule()
        nativeContainer.contentView.addSubview(nativeFirst)
        nativeContainer.contentView.addSubview(nativeSecond)

        for subview in [
            titleLabel, closeButton, headlineLabel, bodyLabel, weaveCaption, nativeContainer, nativeCaption, valueLabel,
            minusButton, plusButton, nativeMinus, nativePlus, switchLabel, mergeSwitch, reverseButton, progressSlider,
            backdropControl, statusLabel,
        ] {
            view.addSubview(subview)
        }
        applyColors()
        updateStatus()
    }

    private func configureButton(_ button: UIButton, symbol: String, label: String, identifier: String) {
        button.configuration?.image = UIImage(systemName: symbol)
        button.configuration?.baseForegroundColor = .white
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
    }

    private func applyColors() {
        let scrim = UIColor(white: 0, alpha: 0.5)
        for label in [titleLabel, headlineLabel, bodyLabel, weaveCaption, nativeCaption, switchLabel, statusLabel] {
            label.textColor = .white
            label.backgroundColor = scrim
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
        }
        for control in [closeButton, reverseButton, backdropControl] as [UIView] {
            control.overrideUserInterfaceStyle = .dark
        }
        mergeSwitch.overrideUserInterfaceStyle = .dark
        progressSlider.overrideUserInterfaceStyle = .dark
    }

    // MARK: Layout

    private func layoutContent() {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let width = min(safe.width - 40, 520)
        let left = safe.midX - width / 2
        titleLabel.frame = CGRect(x: left, y: safe.minY + 4, width: 120, height: 36)
        closeButton.frame = CGRect(x: left + width - 88, y: safe.minY + 4, width: 88, height: 44)
        var y = safe.minY + 56
        headlineLabel.frame = CGRect(x: left, y: y, width: width, height: 26)
        y += 30
        bodyLabel.frame = CGRect(x: left, y: y, width: width, height: 40)
        y += 48
        weaveCaption.frame = CGRect(x: left, y: y, width: width, height: 24)
        y += 30
        let size = Self.stepperSize
        weaveStepper = CGRect(x: safe.midX - size.width / 2, y: y + 12, width: size.width, height: size.height)
        y += size.height + 28
        let rowY = y
        switchLabel.frame = CGRect(x: left, y: rowY + 6, width: 80, height: 30)
        mergeSwitch.frame.origin = CGPoint(x: left + 90, y: rowY + 4)
        reverseButton.frame = CGRect(x: left + width - 110, y: rowY, width: 110, height: 40)
        y += 48
        progressSlider.frame = CGRect(x: left, y: y, width: width, height: 34)
        y += 44
        nativeCaption.frame = CGRect(x: left, y: y, width: width, height: 40)
        y += 48
        nativeStepper = CGRect(x: safe.midX - size.width / 2, y: y + 12, width: size.width, height: size.height)
        y += size.height + 28
        backdropControl.frame = CGRect(x: left, y: y, width: min(width, 240), height: 32)
        statusLabel.frame = CGRect(x: left, y: y + 40, width: width, height: 56)

        let button = CGSize(width: 52, height: 52)
        let offset = Self.buttonOffset
        for (control, stepper, sign) in [(minusButton, weaveStepper, -1.0), (plusButton, weaveStepper, 1.0), (nativeMinus, nativeStepper, -1.0), (nativePlus, nativeStepper, 1.0)] {
            control.frame = CGRect(
                x: stepper.midX + sign * offset - button.width / 2, y: stepper.midY - button.height / 2,
                width: button.width, height: button.height
            )
        }
        valueLabel.frame = CGRect(x: weaveStepper.midX - 26, y: weaveStepper.midY - 16, width: 52, height: 32)
        nativeContainer.frame = nativeStepper.insetBy(dx: -20, dy: -20)
        layoutNativeTwin()
        for label in [titleLabel, headlineLabel, bodyLabel, weaveCaption, nativeCaption, switchLabel, statusLabel] {
            let fitted = label.sizeThatFits(CGSize(width: label.frame.width, height: .greatestFiniteMagnitude))
            label.frame.size = CGSize(width: min(fitted.width + 14, label.frame.width), height: fitted.height + 6)
        }
        applyPanels()
    }

    /// Places Apple's two glass views for the current progress: the same poses
    /// as GlassWeave's two surfaces, as capsule frames.
    private func layoutNativeTwin() {
        let progress = transition?.progress ?? pinnedProgress ?? 0
        guard let blob = try? Self.merge.blob(progress: progress) else { return }
        let size = Self.stepperSize
        let unit = min(size.width, size.height) / 2
        let origin = CGPoint(x: nativeStepper.midX - nativeContainer.frame.minX, y: nativeStepper.midY - nativeContainer.frame.minY)
        let views = [nativeFirst, nativeSecond]
        for (view, primitive) in zip(views, blob.primitives) {
            let box: CGRect
            switch primitive {
            case let .circle(center, radius):
                box = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            case let .capsule(from, to, radius):
                box = CGRect(
                    x: min(from.x, to.x) - radius, y: min(from.y, to.y) - radius,
                    width: abs(from.x - to.x) + radius * 2, height: radius * 2
                )
            case .box:
                box = .zero
            }
            view.frame = CGRect(x: origin.x + box.minX * unit, y: origin.y + box.minY * unit, width: box.width * unit, height: box.height * unit)
        }
    }

    /// Gives the surface the merged panel, and creates the transition once.
    private func applyPanels() {
        guard let surface else { return }
        if let transition {
            transition.refresh()
        } else {
            do {
                let transition = try SurfaceTransition(surface: surface, progress: pinnedProgress ?? 0) { [weak self] progress in
                    self?.panels(for: progress) ?? []
                }
                transition.progressHandler = { [weak self] _ in self?.progressChanged() }
                self.transition = transition
                if let pinnedProgress {
                    mergeSwitch.isOn = pinnedProgress >= 0.5
                    progressSlider.value = Float(pinnedProgress)
                    valueLabel.alpha = pinnedProgress >= 0.5 ? 1 : 0
                }
            } catch {
                statusLabel.text = String(describing: error)
            }
        }
        scheduleStatus()
    }

    // MARK: Actions

    /// The native switch: merge or separate with the spring, and fade the value
    /// with ordinary UIKit animation (the glass is decorative; the buttons
    /// never move).
    private func setMerged(_ merged: Bool, animated: Bool) {
        mergeSwitch.setOn(merged, animated: animated)
        try? transition?.setTarget(merged ? 1 : 0)
        let reduced = surface?.accessibilitySettings.reduceMotion == true
        let change = {
            self.valueLabel.alpha = merged ? 1 : 0
            self.valueLabel.transform = merged ? .identity : CGAffineTransform(scaleX: 0.85, y: 0.85)
        }
        valueLabel.isAccessibilityElement = merged
        if animated, !reduced {
            UIView.animate(withDuration: 0.4, delay: merged ? 0.12 : 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: change)
        } else {
            change()
        }
        scheduleStatus()
    }

    /// The native button: turns the flight around at any moment.
    private func reverseTapped() {
        guard let transition else { return }
        transition.reverse()
        let merged = transition.target >= 0.5
        mergeSwitch.setOn(merged, animated: true)
        UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.valueLabel.alpha = merged ? 1 : 0
            self.valueLabel.transform = merged ? .identity : CGAffineTransform(scaleX: 0.85, y: 0.85)
        }
        valueLabel.isAccessibilityElement = merged
        scheduleStatus()
    }

    /// The native slider: sets the progress by hand, with no spring.
    private func sliderMoved() {
        isScrubbing = true
        let value = Double(progressSlider.value)
        try? transition?.scrub(to: value)
        mergeSwitch.setOn(value >= 0.5, animated: false)
        valueLabel.alpha = CGFloat(min(max((value - 0.5) * 2, 0), 1))
        valueLabel.isAccessibilityElement = value >= 0.5
        scheduleStatus()
    }

    /// Called for every change of progress, by the spring or by the slider.
    private func progressChanged() {
        guard let transition else { return }
        if !isScrubbing {
            progressSlider.value = Float(transition.progress)
            if let lastVelocity { largestVelocityChange = max(largestVelocityChange, abs(transition.velocity - lastVelocity)) }
        }
        lastVelocity = transition.velocity
        layoutNativeTwin()
    }

    /// A tap on a native button, which works the same at every progress.
    private func step(_ delta: Int) {
        quantity = min(max(quantity + delta, 0), 99)
        updateValue()
    }

    private func updateValue() {
        valueLabel.text = "\(quantity)"
        valueLabel.accessibilityLabel = String(localized: "Quantity \(quantity)")
    }

    // MARK: Status

    private func scheduleStatus() {
        updateStatus()
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            self?.updateStatus()
        }
    }

    private func updateStatus() {
        guard let surface else {
            if case let .failure(error) = rendering { statusLabel.text = String(describing: error) }
            return
        }
        let settings = surface.accessibilitySettings
        var parts = [
            "progress " + String(format: "%.2f", transition?.progress ?? 0),
            "target " + String(format: "%.2f", transition?.target ?? 0),
            "v " + String(format: "%.1f", transition?.velocity ?? 0),
            "largest dv " + String(format: "%.1f", largestVelocityChange),
            "quantity \(quantity)",
            "submitted \(submitted)",
            "after settle \(settledMark.map { "+\(submitted - $0)" } ?? "-")",
            surface.isAnimating ? "clock on" : "clock off",
            "drawn " + surface.renderer.drawnVariants.map(\.rawValue).joined(separator: ","),
        ]
        if settings.reduceMotion { parts.append("Reduce Motion") }
        if settings.reduceTransparency { parts.append("Reduce Transparency") }
        statusLabel.text = parts.joined(separator: " | ")
    }
}
