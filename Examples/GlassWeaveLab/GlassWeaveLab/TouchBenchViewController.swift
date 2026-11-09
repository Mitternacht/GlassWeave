import GlassWeave
import GlassWeaveUIKit
import Metal
import UIKit

/// The touch page (GW-12): glass that answers a finger, next to Apple's own.
///
/// - **Top group: GlassWeave glass.** A clear pill with a native button inside
///   it, and a round button, drawn by one `GlassSurfaceView`. Touching the glass
///   shows a soft finger light that follows the finger, one restrained ring that
///   travels out and bends the backdrop a little, and a gleam on the rim nearest
///   the finger (``GlassTouch/standard``). The native buttons keep their own
///   tap: the surface takes no touches, a ``GlassTouchObserver`` on the page
///   only watches them.
/// - **Bottom group: `UIGlassEffect`, interactive.** The same two shapes in
///   Apple's glass with its own touch response, on the same backdrop, as the
///   benchmark for restraint.
/// - **Status line.** Taps on the native buttons, the live touches, the surface's
///   submitted frames, and the submissions since the response settled (it must
///   stay at +0: the page draws on demand again once a touch is over).
///
/// `-lab.touch YES` opens it; `-lab.touchBackdrop orbs|stage|grid` picks the backdrop
/// (default orbs, a colorful dusk with soft spheres; stage is the dark page; grid is a dot lattice that shows the ring's bending).
/// `-lab.touch.auto YES` taps the pill once through the surface's touch API.
/// `-lab.touch.pin "pill:0.3:0.5:0.2;round:0.5:0.5:0.35:0.2"` pins synthetic
/// touches for captures: panel (`pill` or `round`), the position as fractions of
/// that panel, the age in seconds, and optionally how long it was held before
/// it lifted. A pinned touch is a frozen moment of the response (no clock, no
/// interaction), so a capture shows exactly that time.
final class TouchBenchViewController: UIViewController {
    private enum Backdrop: Int, CaseIterable {
        case orbs, stage, grid

        var page: BenchPage {
            switch self {
            case .orbs: .orbs
            case .stage: .stage
            case .grid: .dotGrid
            }
        }
        var title: String {
            switch self {
            case .orbs: String(localized: "Orbs")
            case .stage: String(localized: "Stage")
            case .grid: String(localized: "Grid")
            }
        }
        var identifier: String {
            switch self {
            case .orbs: "orbs"
            case .stage: "stage"
            case .grid: "grid"
            }
        }
    }

    private struct Rendering {
        let surface: GlassSurfaceView
        let background: BenchBackground
    }

    private struct Pin {
        var round: Bool
        var x: Double
        var y: Double
        var age: Double
        var held: Double?
    }

    private var rendering: Result<Rendering, any Error>?
    private var producedKey: String?
    private var backdrop: Backdrop
    private let pins: [Pin]
    private var pinsApplied = false

    private let titleLabel = UILabel()
    private let closeButton = UIButton(configuration: .glass())
    private let statusLabel = UILabel()
    private let backdropControl = UISegmentedControl(items: Backdrop.allCases.map(\.title))
    private let weaveCaption = UILabel()
    private let nativeCaption = UILabel()
    private var weavePill = CGRect.zero
    private var weaveRound = CGRect.zero
    private let weavePillButton = UIButton(configuration: .plain())
    private let weaveRoundButton = UIButton(configuration: .plain())
    private let nativePill = NativeGlassView(configuration: .init(isInteractive: true))
    private let nativeRound = NativeGlassView(configuration: .init(isInteractive: true))
    private let nativePillButton = UIButton(configuration: .plain())
    private let nativeRoundButton = UIButton(configuration: .plain())

    private var taps = 0
    private var submitted = 0
    private var settledMark: Int?
    private var statusTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        backdrop = Backdrop.allCases.first { $0.identifier == defaults.string(forKey: "lab.touchBackdrop") } ?? .orbs
        pins = Self.parsePins(defaults.string(forKey: "lab.touch.pin"))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// `panel:x:y:age[:held]` entries separated by semicolons.
    private static func parsePins(_ text: String?) -> [Pin] {
        guard let text else { return [] }
        return text.split(separator: ";").compactMap { entry in
            let parts = entry.split(separator: ":").map(String.init)
            guard parts.count >= 4, let x = Double(parts[1]), let y = Double(parts[2]), let age = Double(parts[3]) else { return nil }
            return Pin(round: parts[0] == "round", x: x, y: y, age: age, held: parts.count > 4 ? Double(parts[4]) : nil)
        }
    }

    // MARK: Glass

    /// The page's glass: the same refined, enhanced thick lens as the other
    /// pages, with the standard touch response.
    private static func parameters(bezel: Double, thickness: Double) -> GlassParameters {
        var parameters = RefinedLook.enhancedLens(corner: 999, bezel: bezel, thickness: thickness, dispersion: 0.4, dark: true)
        // POLISH: the bend at the rim is a little quieter still here, so the
        // touch response (a soft pool, a barely-there ring) is what changes.
        parameters.lens.maximumOffset = 5.5
        parameters.touch = .standard
        // `-lab.touch.boost <factor>` scales the three strengths, to inspect the
        // response (never above 1 each).
        let boost = UserDefaults.standard.object(forKey: "lab.touch.boost") == nil ? 1 : UserDefaults.standard.double(forKey: "lab.touch.boost")
        parameters.touch.fingerLight = min(parameters.touch.fingerLight * boost, 1)
        parameters.touch.ripple = min(parameters.touch.ripple * boost, 1)
        parameters.touch.gleam = min(parameters.touch.gleam * boost, 1)
        return parameters
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
        if let surface {
            // One observer on the page: the glass surface takes no touches, so the
            // buttons above it keep their own tap and cancel behavior.
            view.addGestureRecognizer(GlassTouchObserver(surface: surface))
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutContent()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // `-lab.touch.auto YES` taps the pill once through the surface's own
        // touch API (no gesture), to show the response settle: after the
        // finger lifts and the ring ends, the status line must read
        // "after settle +0" and "clock off".
        guard UserDefaults.standard.bool(forKey: "lab.touch.auto"), let surface else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            let point = CGPoint(x: weavePill.minX + weavePill.width * 0.3, y: weavePill.midY)
            surface.beginTouch(id: 1, at: point)
            surface.moveTouch(id: 1, to: CGPoint(x: point.x + 40, y: point.y))
            try? await Task.sleep(for: .milliseconds(150))
            surface.endTouch(id: 1)
            updateStatus()
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
            queue.label = "GlassWeaveLab touch"
            let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
            surface.accessibilityIdentifier = "touch.surface"
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
                // The response is over when no touch is live and the clock has
                // stopped: that frame is the last one, and any later submission
                // counts against the page.
                if let surface = self.surface, surface.activeTouchCount == 0, !surface.isAnimating {
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
        titleLabel.text = String(localized: "Touch")
        titleLabel.accessibilityTraits.insert(.header)
        closeButton.configuration?.title = String(localized: "Close")
        closeButton.accessibilityIdentifier = "touch.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "touch.status"
        weaveCaption.text = String(localized: "GlassWeave glass: touch the pill or the button")
        nativeCaption.text = String(localized: "UIGlassEffect, interactive: Apple's response")
        for label in [weaveCaption, nativeCaption] {
            label.font = .preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 2
        }
        backdropControl.selectedSegmentIndex = backdrop.rawValue
        backdropControl.accessibilityIdentifier = "touch.backdrop"
        backdropControl.addAction(UIAction { [weak self] _ in
            guard let self, let chosen = Backdrop(rawValue: backdropControl.selectedSegmentIndex) else { return }
            backdrop = chosen
            surface?.requestFrame()
            applyColors()
        }, for: .valueChanged)

        configureButton(weavePillButton, title: String(localized: "Tap"), symbol: nil, identifier: "touch.weave.pillButton")
        configureButton(weaveRoundButton, title: nil, symbol: "plus", identifier: "touch.weave.roundButton")
        configureButton(nativePillButton, title: String(localized: "Tap"), symbol: nil, identifier: "touch.native.pillButton")
        configureButton(nativeRoundButton, title: nil, symbol: "plus", identifier: "touch.native.roundButton")
        nativePill.cornerConfiguration = .capsule()
        nativeRound.cornerConfiguration = .capsule()
        nativePill.contentView.addSubview(nativePillButton)
        nativeRound.contentView.addSubview(nativeRoundButton)
        for subview in [titleLabel, closeButton, weaveCaption, nativeCaption, nativePill, nativeRound, weavePillButton, weaveRoundButton, backdropControl, statusLabel] {
            view.addSubview(subview)
        }
        applyColors()
        updateStatus()
    }

    private func configureButton(_ button: UIButton, title: String?, symbol: String?, identifier: String) {
        button.configuration?.title = title
        button.configuration?.image = symbol.flatMap { UIImage(systemName: $0) }
        button.configuration?.baseForegroundColor = .white
        button.accessibilityIdentifier = identifier
        if symbol != nil { button.accessibilityLabel = String(localized: "Add") }
        button.addAction(UIAction { [weak self] _ in
            self?.taps += 1
            self?.updateStatus()
        }, for: .primaryActionTriggered)
    }

    private func applyColors() {
        let scrim = UIColor(white: 0, alpha: 0.5)
        for label in [titleLabel, weaveCaption, nativeCaption, statusLabel] {
            label.textColor = .white
            label.backgroundColor = scrim
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
        }
        closeButton.overrideUserInterfaceStyle = .dark
        backdropControl.overrideUserInterfaceStyle = .dark
    }

    /// Places the glass in two groups: GlassWeave's pill and button, and Apple's.
    private func layoutContent() {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let width = min(safe.width - 40, 520)
        let left = safe.midX - width / 2
        titleLabel.frame = CGRect(x: left, y: safe.minY + 4, width: 120, height: 36)
        closeButton.frame = CGRect(x: left + width - 88, y: safe.minY + 4, width: 88, height: 44)
        let pillHeight: CGFloat = 104
        let roundDiameter: CGFloat = 88
        let captionHeight: CGFloat = 36
        var y = safe.minY + 64
        weaveCaption.frame = CGRect(x: left, y: y, width: width, height: captionHeight)
        y += captionHeight + 8
        weavePill = CGRect(x: left, y: y, width: width, height: pillHeight)
        y += pillHeight + 20
        weaveRound = CGRect(x: left, y: y, width: roundDiameter, height: roundDiameter)
        y += roundDiameter + 28
        nativeCaption.frame = CGRect(x: left, y: y, width: width, height: captionHeight)
        y += captionHeight + 8
        nativePill.frame = CGRect(x: left, y: y, width: width, height: pillHeight)
        y += pillHeight + 20
        nativeRound.frame = CGRect(x: left, y: y, width: roundDiameter, height: roundDiameter)
        y += roundDiameter + 20
        backdropControl.frame = CGRect(x: left, y: y, width: min(width, 300), height: 32)
        statusLabel.frame = CGRect(x: left, y: y + 40, width: width, height: 56)

        let pillButtonSize = CGSize(width: 76, height: 48)
        weavePillButton.frame = CGRect(
            x: weavePill.maxX - pillButtonSize.width - 28, y: weavePill.midY - pillButtonSize.height / 2,
            width: pillButtonSize.width, height: pillButtonSize.height
        )
        nativePillButton.frame = CGRect(
            x: nativePill.bounds.width - pillButtonSize.width - 28, y: (pillHeight - pillButtonSize.height) / 2,
            width: pillButtonSize.width, height: pillButtonSize.height
        )
        weaveRoundButton.frame = weaveRound
        nativeRoundButton.frame = nativeRound.bounds
        for label in [titleLabel, weaveCaption, nativeCaption, statusLabel] {
            let fitted = label.sizeThatFits(CGSize(width: label.frame.width, height: .greatestFiniteMagnitude))
            label.frame.size = CGSize(width: min(fitted.width + 14, label.frame.width), height: min(fitted.height + 6, max(label.frame.height, fitted.height + 6)))
        }
        applyPanels()
    }

    /// Gives the surface the two panels, and the pinned touches once.
    private func applyPanels() {
        guard let surface else { return }
        let panels = [
            GlassPanel(frame: weavePill, parameters: Self.parameters(bezel: 30, thickness: 30)),
            GlassPanel(frame: weaveRound, parameters: Self.parameters(bezel: 26, thickness: 26)),
        ]
        try? surface.setPanels(panels)
        if !pinsApplied, !pins.isEmpty {
            pinsApplied = true
            for pin in pins {
                let frame = pin.round ? weaveRound : weavePill
                surface.pinTouch(
                    at: CGPoint(x: frame.minX + frame.width * pin.x, y: frame.minY + frame.height * pin.y),
                    age: pin.age, heldFor: pin.held
                )
            }
        }
        scheduleStatus()
    }

    // MARK: Status

    /// Updates the status line now and once more shortly after the last draw,
    /// so it shows the settled state.
    private func scheduleStatus() {
        updateStatus()
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
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
            "taps \(taps)",
            "touches \(surface.activeTouchCount)",
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
