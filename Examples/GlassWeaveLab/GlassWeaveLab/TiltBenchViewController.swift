import GlassWeave
import GlassWeaveUIKit
import Metal
import UIKit

/// The tilt page (GW-33): the light of GlassWeave glass follows the tilt of the
/// device, beside Apple's own glass.
///
/// - **Top group: GlassWeave glass.** A pill, a round button and a chrome ring,
///   each a native button on its own panel of glass, on one surface. The light
///   model's azimuth and elevation offset follow a motion source through
///   `GlassTiltLight` (a low-pass filter and a small, bounded amplitude); only
///   the light moves, never the panel or the bend. The simulator has no motion
///   hardware, so the **Roll** and **Lean** sliders play the device: a timer
///   hands the light a sample from them 30 times a second, exactly as the sensor
///   would. On a device the **Core Motion** source reads the real one (wired, not
///   verified without hardware).
/// - **Bottom group: `UIGlassEffect`.** The same three shapes in Apple's glass:
///   the system's own light, which no app can steer.
/// - **Status line.** The light offset in degrees, how many times it was applied
///   (a settled light stops), the pin, the clock and the submitted frames.
///
/// `-lab.tilt YES` opens it; `-lab.tilt.roll <deg>` and `-lab.tilt.lean <deg>`
/// set the sliders' start (roll positive: right edge down, `m30` is -30; lean 0 upright to
/// 90 flat, neutral 40); `-lab.tiltBackdrop paper|orbs|stage` picks the backdrop
/// (default orbs); `-lab.reduceMotion YES` pins the light.
final class TiltBenchViewController: UIViewController {
    // MARK: Launch

    static var launchRequested: Bool {
        UserDefaults.standard.bool(forKey: "lab.tilt")
    }

    /// The laboratory's menu entry, which opens this page over the window.
    static func menuButton(presentedBy presenter: UIViewController, hidden: Bool) -> UIButton {
        let button = UIButton(configuration: .bordered())
        button.configuration?.title = String(localized: "Tilt")
        button.accessibilityIdentifier = "lab.openTilt"
        button.isHidden = hidden
        button.addAction(UIAction { [weak presenter] _ in
            if let presenter { present(from: presenter, animated: true) }
        }, for: .primaryActionTriggered)
        return button
    }

    private static var openedAtLaunch = false

    /// Opens the page once when `-lab.tilt YES` was given.
    static func presentAtLaunch(from presenter: UIViewController) {
        guard !openedAtLaunch, launchRequested else { return }
        openedAtLaunch = true
        present(from: presenter, animated: false)
    }

    /// Presents the page over the whole window, unless `presenter` already
    /// presents something.
    static func present(from presenter: UIViewController, animated: Bool) {
        guard presenter.presentedViewController == nil else { return }
        let page = TiltBenchViewController()
        page.modalPresentationStyle = .fullScreen
        presenter.present(page, animated: animated)
    }

    // MARK: Model

    private enum Backdrop: Int, CaseIterable {
        case orbs, stage, paper

        var page: BenchPage {
            switch self {
            case .paper: .paperDesk
            case .orbs: .orbs
            case .stage: .stage
            }
        }
        var dark: Bool { self != .paper }
        var title: String {
            switch self {
            case .paper: String(localized: "Paper")
            case .orbs: String(localized: "Orbs")
            case .stage: String(localized: "Stage")
            }
        }
        var identifier: String {
            switch self {
            case .paper: "paper"
            case .orbs: "orbs"
            case .stage: "stage"
            }
        }
    }

    private struct Rendering {
        let surface: GlassSurfaceView
        let background: BenchBackground
    }

    /// One shape of the page.
    private struct Piece {
        let name: String
        let size: CGSize
        let symbol: String?
        let title: String?
    }

    private static let pieces = [
        Piece(name: "pill", size: CGSize(width: 140, height: 56), symbol: nil, title: String(localized: "Tilt me")),
        Piece(name: "round", size: CGSize(width: 64, height: 64), symbol: "sun.max.fill", title: nil),
        Piece(name: "ring", size: CGSize(width: 88, height: 88), symbol: "circle.dotted", title: nil),
    ]

    private static let areaHeight: CGFloat = 132
    /// The neutral lean of `GlassTiltLight` (a normal grip), where the slider starts.
    private static let neutralLean = 40.0

    private var rendering: Result<Rendering, any Error>?
    private var producedKey: String?
    private var backdrop: Backdrop

    private let injected = GlassInjectedMotionSource()
    private let coreMotion: (any GlassMotionSource)?
    private var tilt: GlassTiltLight?
    private var sampleTimer: Timer?
    private var tick = 0

    private let titleLabel = UILabel()
    private let closeButton = UIButton(configuration: .glass())
    private let weaveCaption = UILabel()
    private let nativeCaption = UILabel()
    private let rollLabel = UILabel()
    private let leanLabel = UILabel()
    private let rollSlider = UISlider()
    private let leanSlider = UISlider()
    private let sourceControl = UISegmentedControl(items: [String(localized: "Slider"), String(localized: "Core Motion")])
    private let backdropControl = UISegmentedControl(items: Backdrop.allCases.map(\.title))
    private let statusLabel = UILabel()
    private let weaveFrame = CAShapeLayer()
    private let nativeFrame = CAShapeLayer()

    private var buttons: [UIButton] = []
    private var weaveArea = CGRect.zero
    private let nativeContainer = UIView()
    private var nativeGlass: [NativeGlassView] = []
    private var nativeArea = CGRect.zero

    private var statusWidth: CGFloat = 0
    private var taps = 0
    private var submitted = 0
    private var lastFrameTime: TimeInterval?
    private var settleTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        backdrop = Backdrop.allCases.first { $0.identifier == defaults.string(forKey: "lab.tiltBackdrop") } ?? .orbs
        #if canImport(CoreMotion) && os(iOS)
        coreMotion = GlassCoreMotionSource()
        #else
        coreMotion = nil
        #endif
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A launch argument's degrees: a launch argument cannot start with a minus
    /// sign (it would read as the next key), so `m30` means -30.
    private static func launchDegrees(_ text: String?) -> Double? {
        guard var text else { return nil }
        var sign = 1.0
        if text.hasPrefix("m") { sign = -1; text.removeFirst() }
        return Double(text).map { $0 * sign }
    }

    // MARK: Glass

    private func parameters(for index: Int) -> GlassParameters {
        let dark = backdrop.dark
        switch Self.pieces[index].name {
        case "ring":
            return RefinedLook.chromeRing(diameter: Double(Self.pieces[index].size.width))
        case "round":
            return RefinedLook.enhancedLens(corner: 999, bezel: 20, thickness: 22, dispersion: 0.2, dark: dark)
        default:
            return RefinedLook.enhancedLens(corner: 999, bezel: 22, thickness: 24, dispersion: 0.2, dark: dark)
        }
    }

    private var weaveFrames: [CGRect] {
        guard weaveArea.width > 0 else { return [] }
        let total = Self.pieces.reduce(0) { $0 + $1.size.width }
        let gap = max((weaveArea.width - total) / CGFloat(Self.pieces.count + 1), 8)
        var x = weaveArea.minX + gap
        return Self.pieces.map { piece in
            defer { x += piece.size.width + gap }
            return CGRect(x: x, y: weaveArea.midY - piece.size.height / 2, width: piece.size.width, height: piece.size.height)
        }
    }

    private func applyPanels() {
        guard let surface, weaveArea.width > 0 else { return }
        let frames = weaveFrames
        do {
            try surface.setPanels(zip(frames, Self.pieces.indices).map { GlassPanel(frame: $0, parameters: parameters(for: $1)) })
        } catch {
            statusLabel.text = String(describing: error)
        }
        for (button, frame) in zip(buttons, frames) { button.frame = frame }
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = backdrop.dark ? .black : .white
        if UserDefaults.standard.bool(forKey: "lab.increaseContrast") {
            traitOverrides.accessibilityContrast = .high
        }
        setUpRendering()
        setUpContent()
        startTilt()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutContent()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The simulated sensor: a sample from the sliders 30 times a second,
        // delivered only while the source runs (a hidden page or a pinned light
        // receives none).
        sampleTimer?.invalidate()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: GlassTiltLight.nominalInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleTick() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sampleTimer?.invalidate()
        sampleTimer = nil
        settleTask?.cancel()
        tilt?.invalidate()
    }

    private func sampleTick() {
        tick += 1
        let sample = GlassMotionSample(
            rollDegrees: Double(rollSlider.value), leanDegrees: Double(leanSlider.value),
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        injected.send(sample)
        if tick % 6 == 0 { updateStatus() }
    }

    // MARK: Rendering

    private func setUpRendering() {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw BenchBackground.Failure.shaderUnavailable("no Metal device") }
            guard let queue = device.makeCommandQueue() else { throw BenchBackground.Failure.shaderUnavailable("no command queue") }
            queue.label = "GlassWeaveLab tilt"
            let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
            surface.accessibilityIdentifier = "tilt.surface"
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
            surface.accessibilitySettingsHandler = { [weak self] _ in self?.updateStatus() }
            surface.renderObserver = { [weak self] outcome in
                guard let self else { return }
                if case .submitted = outcome {
                    self.submitted += 1
                    self.lastFrameTime = ProcessInfo.processInfo.systemUptime
                }
                self.scheduleSettledStatus()
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

    /// The tilt light: it starts the source while the surface is visible.
    private func startTilt() {
        guard let surface else { return }
        do {
            tilt = try GlassTiltLight(surface: surface, source: injected)
        } catch {
            statusLabel.text = String(describing: error)
        }
    }

    // MARK: Content

    private func setUpContent() {
        let defaults = UserDefaults.standard
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.text = String(localized: "Tilt")
        titleLabel.accessibilityTraits.insert(.header)
        closeButton.configuration?.title = String(localized: "Close")
        closeButton.accessibilityIdentifier = "tilt.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        weaveCaption.text = String(localized: "GlassWeave glass: the light follows the tilt of the device, a few degrees, smoothed. Only the light moves.")
        nativeCaption.text = String(localized: "UIGlassEffect: Apple's glass in the same shapes. Its light is the system's own.")
        for label in [weaveCaption, nativeCaption] {
            label.font = .preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "tilt.status"

        rollSlider.minimumValue = -45
        rollSlider.maximumValue = 45
        rollSlider.value = Float(Self.launchDegrees(defaults.string(forKey: "lab.tilt.roll")) ?? 0)
        leanSlider.minimumValue = 0
        leanSlider.maximumValue = 90
        leanSlider.value = Float(Self.launchDegrees(defaults.string(forKey: "lab.tilt.lean")) ?? Self.neutralLean)
        rollSlider.accessibilityIdentifier = "tilt.roll"
        leanSlider.accessibilityIdentifier = "tilt.lean"
        rollSlider.accessibilityLabel = String(localized: "Roll, degrees")
        leanSlider.accessibilityLabel = String(localized: "Lean, degrees")
        for slider in [rollSlider, leanSlider] {
            slider.addAction(UIAction { [weak self] _ in self?.updateStatus() }, for: .valueChanged)
        }
        for label in [rollLabel, leanLabel] {
            label.font = .preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
        }

        sourceControl.selectedSegmentIndex = 0
        sourceControl.accessibilityIdentifier = "tilt.source"
        // The simulator has no motion hardware: the Core Motion segment is there
        // only where the device has the sensor.
        let hasSensor = coreMotion?.isAvailable == true
        sourceControl.setEnabled(hasSensor, forSegmentAt: 1)
        if !hasSensor { sourceControl.setTitle(String(localized: "Core Motion (n/a)"), forSegmentAt: 1) }
        sourceControl.addAction(UIAction { [weak self] _ in
            guard let self, let tilt else { return }
            if sourceControl.selectedSegmentIndex == 1, let coreMotion {
                tilt.source = coreMotion
            } else {
                tilt.source = injected
            }
            updateStatus()
        }, for: .valueChanged)

        backdropControl.selectedSegmentIndex = backdrop.rawValue
        backdropControl.accessibilityIdentifier = "tilt.backdrop"
        backdropControl.addAction(UIAction { [weak self] _ in
            guard let self, let chosen = Backdrop(rawValue: backdropControl.selectedSegmentIndex) else { return }
            backdrop = chosen
            producedKey = nil
            view.backgroundColor = chosen.dark ? .black : .white
            applyColors()
            applyPanels()
            surface?.requestFrame()
        }, for: .valueChanged)

        for layer in [weaveFrame, nativeFrame] {
            layer.fillColor = nil
            layer.lineWidth = 1
            layer.lineDashPattern = [4, 6]
            view.layer.addSublayer(layer)
        }

        // The weave group: a native button over each panel (the surface takes no
        // touches).
        for piece in Self.pieces {
            let button = makeButton(piece, identifier: "tilt.\(piece.name)")
            view.addSubview(button)
            buttons.append(button)
        }

        // Apple's group: the same shapes in UIGlassEffect.
        for piece in Self.pieces {
            let glass = NativeGlassView(configuration: .init(isInteractive: true))
            glass.cornerConfiguration = .capsule()
            let button = makeButton(piece, identifier: "tilt.native.\(piece.name)")
            button.frame = CGRect(origin: .zero, size: piece.size)
            glass.contentView.addSubview(button)
            nativeContainer.addSubview(glass)
            nativeGlass.append(glass)
        }

        for subview in [titleLabel, closeButton, weaveCaption, nativeCaption, nativeContainer, rollLabel, rollSlider, leanLabel, leanSlider, sourceControl, backdropControl, statusLabel] {
            view.addSubview(subview)
        }
        for button in buttons { view.bringSubviewToFront(button) }
        applyColors()
        updateStatus()
    }

    private func makeButton(_ piece: Piece, identifier: String) -> UIButton {
        let button = UIButton(configuration: .plain())
        button.configuration?.title = piece.title
        button.configuration?.image = piece.symbol.flatMap { UIImage(systemName: $0) }
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = piece.title ?? piece.name
        button.addAction(UIAction { [weak self] _ in
            self?.taps += 1
            self?.updateStatus()
        }, for: .primaryActionTriggered)
        return button
    }

    private func applyColors() {
        let dark = backdrop.dark
        let ink: UIColor = dark ? .white : .black
        let scrim = UIColor(white: dark ? 0 : 1, alpha: 0.6)
        for label in [titleLabel, weaveCaption, nativeCaption, statusLabel, rollLabel, leanLabel] {
            label.textColor = ink
            label.backgroundColor = scrim
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
        }
        for button in buttons { button.configuration?.baseForegroundColor = ink }
        for glass in nativeGlass {
            for case let button as UIButton in glass.contentView.subviews { button.configuration?.baseForegroundColor = ink }
        }
        for control in [closeButton, sourceControl, backdropControl] as [UIView] {
            control.overrideUserInterfaceStyle = dark ? .dark : .light
        }
        for layer in [weaveFrame, nativeFrame] {
            layer.strokeColor = UIColor(white: dark ? 1 : 0, alpha: 0.16).cgColor
        }
    }

    // MARK: Layout

    private func layoutContent() {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let width = min(safe.width - 32, 520)
        let left = safe.midX - width / 2
        titleLabel.frame = CGRect(x: left, y: safe.minY + 4, width: 120, height: 36)
        closeButton.frame = CGRect(x: left + width - 88, y: safe.minY + 4, width: 88, height: 44)
        var y = safe.minY + 54
        weaveCaption.frame = CGRect(x: left, y: y, width: width, height: 40)
        y += 54
        let weave = CGRect(x: left, y: y, width: width, height: Self.areaHeight)
        y += Self.areaHeight + 8
        nativeCaption.frame = CGRect(x: left, y: y, width: width, height: 40)
        y += 54
        let native = CGRect(x: left, y: y, width: width, height: Self.areaHeight)
        y += Self.areaHeight + 14
        rollLabel.frame = CGRect(x: left, y: y, width: 104, height: 24)
        rollSlider.frame = CGRect(x: left + 112, y: y - 4, width: width - 112, height: 32)
        y += 34
        leanLabel.frame = CGRect(x: left, y: y, width: 104, height: 24)
        leanSlider.frame = CGRect(x: left + 112, y: y - 4, width: width - 112, height: 32)
        y += 38
        sourceControl.frame = CGRect(x: left, y: y, width: width, height: 32)
        y += 40
        backdropControl.frame = CGRect(x: left, y: y, width: width, height: 32)
        y += 40
        statusLabel.frame = CGRect(x: left, y: y, width: width, height: 64)
        statusWidth = width
        for label in [titleLabel, weaveCaption, nativeCaption, statusLabel] {
            let fitted = label.sizeThatFits(CGSize(width: label.frame.width, height: .greatestFiniteMagnitude))
            label.frame.size = CGSize(width: min(fitted.width + 14, label.frame.width), height: fitted.height + 6)
        }
        for (layer, area) in [(weaveFrame, weave), (nativeFrame, native)] {
            layer.path = UIBezierPath(roundedRect: area.insetBy(dx: -6, dy: -6), cornerRadius: 30).cgPath
        }
        weaveArea = weave
        nativeArea = native
        nativeContainer.frame = native
        let total = Self.pieces.reduce(0) { $0 + $1.size.width }
        let gap = max((native.width - total) / CGFloat(Self.pieces.count + 1), 8)
        var x = gap
        for (glass, piece) in zip(nativeGlass, Self.pieces) {
            glass.frame = CGRect(x: x, y: (native.height - piece.size.height) / 2, width: piece.size.width, height: piece.size.height)
            x += piece.size.width + gap
        }
        applyPanels()
    }

    // MARK: Status

    /// A frame was submitted: refresh now and once more when the light has
    /// settled, so the status shows the quiet state too.
    private func scheduleSettledStatus() {
        updateStatus()
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.updateStatus()
        }
    }

    private func updateStatus() {
        rollLabel.text = String(format: "%@ %+.0f°", String(localized: "Roll"), rollSlider.value)
        leanLabel.text = String(format: "%@ %.0f°", String(localized: "Lean"), leanSlider.value)
        guard let surface else {
            if case let .failure(error) = rendering { statusLabel.text = String(describing: error) }
            return
        }
        var parts: [String] = []
        if let tilt {
            parts.append(String(format: "light az %+.1f el %+.1f", tilt.offset.azimuth, tilt.offset.elevation))
            parts.append("applied \(tilt.appliedCount)")
            parts.append(tilt.isPinned ? "pinned" : "free")
            parts.append("sensor " + (tilt.source.isRunning ? "on" : "off"))
        }
        parts.append(contentsOf: [
            surface.isAnimating ? "clock on" : "clock off",
            "submitted \(submitted)",
            // A settled light draws nothing: this keeps growing while it rests.
            "last frame " + (lastFrameTime.map { String(format: "%.1f s ago", ProcessInfo.processInfo.systemUptime - $0) } ?? "none"),
            "taps \(taps)",
        ])
        let settings = surface.accessibilitySettings
        if settings.reduceMotion { parts.append("Reduce Motion") }
        if settings.reduceTransparency { parts.append("Reduce Transparency") }
        statusLabel.text = parts.joined(separator: " | ")
        // The text grows and shrinks: keep the label as tall as it needs.
        if statusWidth > 0 {
            let fitted = statusLabel.sizeThatFits(CGSize(width: statusWidth - 14, height: .greatestFiniteMagnitude))
            statusLabel.frame.size = CGSize(width: statusWidth, height: fitted.height + 6)
        }
    }
}
