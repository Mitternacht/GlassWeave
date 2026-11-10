import GlassWeave
import GlassWeaveUIKit
import Metal
import UIKit

/// The drag page (GW-32): glass panels that follow a finger on a spring and
/// merge by proximity, beside Apple's own container merge.
///
/// - **Top group: GlassWeave glass, custom to custom.** A pill, a round button
///   and a rounded square, each a native button on its own panel of glass. Drag
///   one with a finger: the glass follows on a spring (`PanelSpring`, on the
///   surface's effect clock) and changes course in flight without a jump. When
///   two panels come within about 40 points of each other they start to join,
///   and once they are within 6 points they are one smooth shape, drawn as one
///   panel (`GlassProximityMerge`); pull them apart and the join lets go 14
///   points later than it formed (hysteresis, so a finger hovering at the
///   threshold never flickers). The buttons are ordinary UIKit controls: the
///   surface takes no touches, each panel's hit area is its own frame, and a
///   tap on a button works in every state.
/// - **Bottom group: `UIGlassEffect` in a `UIGlassContainerEffect`.** The same
///   three shapes in Apple's glass, merged by the system's container (a
///   separate material system), dragged the same way. Ours merges custom glass
///   with custom glass; Apple's merges Apple's glass with Apple's glass.
/// - **Status line.** Each pair's gap, progress and merged state, the spring and
///   clock state, the surface's submitted frames, and the submissions since the
///   last motion settled (it must stay at +0: the page draws on demand again).
///
/// `-lab.drag YES` opens it; `-lab.dragBackdrop stage|orbs` picks the backdrop
/// (default stage); `-lab.drag.pin "pill:0.3:0.3;round:0.55:0.3;square:0.5:0.8"`
/// pins the panels' centers (as fractions of the group's area) with no spring
/// and no clock, for captures; `-lab.drag.auto YES` brings the round button to
/// the pill, merges them, and pulls them apart again, through the same code a
/// finger uses.
final class DragBenchViewController: UIViewController {
    // MARK: Launch

    static var launchRequested: Bool {
        UserDefaults.standard.bool(forKey: "lab.drag")
    }

    /// The laboratory's menu entry, which opens this page over the window.
    static func menuButton(presentedBy presenter: UIViewController, hidden: Bool) -> UIButton {
        let button = UIButton(configuration: .bordered())
        button.configuration?.title = String(localized: "Drag")
        button.accessibilityIdentifier = "lab.openDrag"
        button.isHidden = hidden
        button.addAction(UIAction { [weak presenter] _ in
            if let presenter { present(from: presenter, animated: true) }
        }, for: .primaryActionTriggered)
        return button
    }

    private static var openedAtLaunch = false

    /// Opens the page once when `-lab.drag YES` was given.
    static func presentAtLaunch(from presenter: UIViewController) {
        guard !openedAtLaunch, launchRequested else { return }
        openedAtLaunch = true
        present(from: presenter, animated: false)
    }

    /// Presents the page over the whole window, unless `presenter` already
    /// presents something.
    static func present(from presenter: UIViewController, animated: Bool) {
        guard presenter.presentedViewController == nil else { return }
        let page = DragBenchViewController()
        page.modalPresentationStyle = .fullScreen
        presenter.present(page, animated: animated)
    }

    // MARK: Model

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

    /// One draggable panel.
    private struct Piece {
        let name: String
        let size: CGSize
        let corner: CGFloat
        let symbol: String?
        let title: String?
        let start: CGPoint
    }

    private static let pieces = [
        Piece(name: "pill", size: CGSize(width: 148, height: 56), corner: 28, symbol: nil, title: String(localized: "Drag me"), start: CGPoint(x: 0.3, y: 0.28)),
        Piece(name: "round", size: CGSize(width: 64, height: 64), corner: 32, symbol: "plus", title: nil, start: CGPoint(x: 0.82, y: 0.28)),
        Piece(name: "square", size: CGSize(width: 84, height: 84), corner: 26, symbol: "heart.fill", title: nil, start: CGPoint(x: 0.52, y: 0.78)),
    ]

    private static let areaHeight: CGFloat = 228

    private var rendering: Result<Rendering, any Error>?
    private var producedKey: String?
    private var backdrop: Backdrop
    private let pins: [String: CGPoint]
    private let autoRun: Bool

    private let titleLabel = UILabel()
    private let closeButton = UIButton(configuration: .glass())
    private let weaveCaption = UILabel()
    private let nativeCaption = UILabel()
    private let backdropControl = UISegmentedControl(items: Backdrop.allCases.map(\.title))
    private let resetButton = UIButton(configuration: .glass())
    private let statusLabel = UILabel()
    private let weaveFrame = CAShapeLayer()
    private let nativeFrame = CAShapeLayer()

    // GlassWeave group.
    private var springs: [PanelSpring] = []
    private var buttons: [UIButton] = []
    private var tracker = GlassProximityMerge.Tracker()
    private var weaveArea = CGRect.zero
    private var appliedArea = CGRect.zero
    // Apple's group.
    private let nativeContainer = UIVisualEffectView(effect: nil)
    private var nativeGlass: [NativeGlassView] = []
    private var nativeButtons: [UIButton] = []
    private var nativeArea = CGRect.zero

    /// Each group's centers as fractions of its area.
    private var fractions: [[CGPoint]] = [
        DragBenchViewController.pieces.map(\.start), DragBenchViewController.pieces.map(\.start),
    ]
    private var dragStart: [Int: CGPoint] = [:]
    private var activeDrags: Set<Int> = []

    private var taps = 0
    private var submitted = 0
    private var settledMark: Int?
    private var statusTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        backdrop = Backdrop.allCases.first { $0.identifier == defaults.string(forKey: "lab.dragBackdrop") } ?? .stage
        pins = Self.parsePins(defaults.string(forKey: "lab.drag.pin"))
        autoRun = defaults.bool(forKey: "lab.drag.auto")
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// `name:x:y` entries separated by semicolons.
    private static func parsePins(_ text: String?) -> [String: CGPoint] {
        guard let text else { return [:] }
        var result: [String: CGPoint] = [:]
        for entry in text.split(separator: ";") {
            let parts = entry.split(separator: ":").map(String.init)
            if parts.count >= 3, let x = Double(parts[1]), let y = Double(parts[2]) {
                result[parts[0]] = CGPoint(x: x, y: y)
            }
        }
        return result
    }

    // MARK: Glass

    /// The page's glass: the refined, clean thick lens of the other pages. The
    /// shape is set per group of merged panels.
    private static func parameters() -> GlassParameters {
        RefinedLook.enhancedLens(corner: 999, bezel: 22, thickness: 24, dispersion: 0.3, dark: true)
    }

    private var reduceMotion: Bool {
        surface?.accessibilitySettings.reduceMotion ?? UIAccessibility.isReduceMotionEnabled
    }

    /// Gives the surface one panel per group of merged panels.
    private func applyPanels() {
        guard let surface, springs.count == Self.pieces.count, weaveArea.width > 0 else { return }
        let outlines = zip(springs, Self.pieces).map {
            GlassProximityMerge.Outline.panel(frame: $0.frame, cornerRadius: Double($1.corner))
        }
        do {
            let clusters = try tracker.update(outlines)
            let area = weaveArea
            let panels = try clusters.map { cluster -> GlassPanel in
                var parameters = Self.parameters()
                parameters.shape = .blob(try tracker.merge.blob(for: cluster, of: outlines, in: area))
                return GlassPanel(frame: area, parameters: parameters)
            }
            try surface.setPanels(panels)
        } catch {
            statusLabel.text = String(describing: error)
        }
        for (button, spring) in zip(buttons, springs) { button.frame = spring.frame }
        scheduleStatus()
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
        guard autoRun, !springs.isEmpty else { return }
        // Bring the round button to the pill until they join, then pull it
        // away again: the same targets a finger sets. The status line must then
        // read "after settle +0" and "clock off".
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1.2))
            let pill = Self.pieces[0], round = Self.pieces[1]
            let join = (fractions[0][0].x * weaveArea.width + pill.size.width / 2 + 3 + round.size.width / 2) / weaveArea.width
            move(1, to: CGPoint(x: join, y: fractions[0][0].y))
            try? await Task.sleep(for: .seconds(1.8))
            move(1, to: CGPoint(x: 0.9, y: 0.28))
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        statusTask?.cancel()
        for _ in activeDrags { surface?.endInteraction() }
        activeDrags = []
    }

    // MARK: Rendering

    private func setUpRendering() {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw BenchBackground.Failure.shaderUnavailable("no Metal device") }
            guard let queue = device.makeCommandQueue() else { throw BenchBackground.Failure.shaderUnavailable("no command queue") }
            queue.label = "GlassWeaveLab drag"
            let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
            surface.accessibilityIdentifier = "drag.surface"
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
            surface.accessibilitySettingsHandler = { [weak self] _ in
                self?.applyWeaveInk()
                self?.scheduleStatus()
            }
            surface.renderObserver = { [weak self] outcome in
                guard let self else { return }
                if case .submitted = outcome { self.submitted += 1 }
                // The motion is over when no spring moves, no finger is down
                // and the clock has stopped: that frame is the last one, and
                // any later submission counts against the page.
                if let surface = self.surface, surface.isAnimating == false, !self.anySpringMoving, self.activeDrags.isEmpty {
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

    private var anySpringMoving: Bool {
        springs.contains { $0.isMoving }
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
        titleLabel.text = String(localized: "Drag")
        titleLabel.accessibilityTraits.insert(.header)
        closeButton.configuration?.title = String(localized: "Close")
        closeButton.accessibilityIdentifier = "drag.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        weaveCaption.text = String(localized: "GlassWeave glass, custom to custom: drag a panel close to another and they merge into one shape")
        nativeCaption.text = String(localized: "UIGlassEffect in a UIGlassContainerEffect: Apple's glass merging with Apple's glass, a separate material system")
        for label in [weaveCaption, nativeCaption] {
            label.font = .preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "drag.status"
        backdropControl.selectedSegmentIndex = backdrop.rawValue
        backdropControl.accessibilityIdentifier = "drag.backdrop"
        backdropControl.addAction(UIAction { [weak self] _ in
            guard let self, let chosen = Backdrop(rawValue: backdropControl.selectedSegmentIndex) else { return }
            backdrop = chosen
            surface?.requestFrame()
        }, for: .valueChanged)
        resetButton.configuration?.title = String(localized: "Reset")
        resetButton.accessibilityIdentifier = "drag.reset"
        resetButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            for index in Self.pieces.indices { move(index, to: Self.pieces[index].start) }
        }, for: .primaryActionTriggered)

        for layer in [weaveFrame, nativeFrame] {
            layer.fillColor = nil
            layer.strokeColor = UIColor(white: 1, alpha: 0.16).cgColor
            layer.lineWidth = 1
            layer.lineDashPattern = [4, 6]
            view.layer.addSublayer(layer)
        }

        // The weave group: a spring and a native button per panel. The button
        // is the hit target and the pan carries the drag; the surface takes no
        // touches.
        if let surface {
            for (index, piece) in Self.pieces.enumerated() {
                let button = makeButton(piece, identifier: "drag.\(piece.name)")
                button.tag = index
                button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(weavePan(_:))))
                view.addSubview(button)
                buttons.append(button)
                if let spring = try? PanelSpring(surface: surface, frame: CGRect(origin: .zero, size: piece.size)) {
                    spring.frameHandler = { [weak self] _ in self?.applyPanels() }
                    spring.didSettleHandler = { [weak self] in self?.scheduleStatus() }
                    springs.append(spring)
                }
            }
        }

        // Apple's group.
        let container = UIGlassContainerEffect()
        container.spacing = 40
        nativeContainer.effect = container
        nativeContainer.clipsToBounds = false
        for (index, piece) in Self.pieces.enumerated() {
            let glass = NativeGlassView(configuration: .init(isInteractive: true))
            glass.cornerConfiguration = piece.corner >= min(piece.size.width, piece.size.height) / 2 ? .capsule() : .corners(radius: .fixed(piece.corner))
            glass.tag = index
            glass.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(nativePan(_:))))
            let button = makeButton(piece, identifier: "drag.native.\(piece.name)")
            button.frame = CGRect(origin: .zero, size: piece.size)
            glass.contentView.addSubview(button)
            nativeContainer.contentView.addSubview(glass)
            nativeGlass.append(glass)
            nativeButtons.append(button)
        }

        for subview in [titleLabel, closeButton, weaveCaption, nativeCaption, nativeContainer, backdropControl, resetButton, statusLabel] {
            view.addSubview(subview)
        }
        // The weave buttons sit above the native container and the labels.
        for button in buttons { view.bringSubviewToFront(button) }
        applyColors()
        updateStatus()
    }

    private func makeButton(_ piece: Piece, identifier: String) -> UIButton {
        let button = UIButton(configuration: .plain())
        button.configuration?.title = piece.title
        button.configuration?.image = piece.symbol.flatMap { UIImage(systemName: $0) }
        button.configuration?.baseForegroundColor = .white
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = piece.title ?? piece.name
        button.accessibilityHint = String(localized: "Drag to move. Panels merge when they are close.")
        button.addAction(UIAction { [weak self] _ in
            self?.taps += 1
            self?.updateStatus()
        }, for: .primaryActionTriggered)
        return button
    }

    private func applyColors() {
        let scrim = UIColor(white: 0, alpha: 0.5)
        for label in [titleLabel, weaveCaption, nativeCaption, statusLabel] {
            label.textColor = .white
            label.backgroundColor = scrim
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
        }
        for control in [closeButton, resetButton, backdropControl] as [UIView] {
            control.overrideUserInterfaceStyle = .dark
        }
        applyWeaveInk()
    }

    /// Under Reduce Transparency the surface is an opaque, system-colored
    /// sheet, so GlassWeave's own buttons take the system label color instead
    /// of white, which would be unreadable on it.
    private func applyWeaveInk() {
        let ink: UIColor = surface?.accessibilitySettings.reduceTransparency == true ? .label : .white
        for button in buttons { button.configuration?.baseForegroundColor = ink }
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
        y += 46
        let weave = CGRect(x: left, y: y, width: width, height: Self.areaHeight)
        y += Self.areaHeight + 8
        nativeCaption.frame = CGRect(x: left, y: y, width: width, height: 40)
        y += 46
        let native = CGRect(x: left, y: y, width: width, height: Self.areaHeight)
        y += Self.areaHeight + 10
        backdropControl.frame = CGRect(x: left, y: y, width: min(width - 100, 220), height: 32)
        resetButton.frame = CGRect(x: left + width - 88, y: y - 4, width: 88, height: 40)
        statusLabel.frame = CGRect(x: left, y: y + 42, width: width, height: 64)
        for label in [titleLabel, weaveCaption, nativeCaption, statusLabel] {
            let fitted = label.sizeThatFits(CGSize(width: label.frame.width, height: .greatestFiniteMagnitude))
            label.frame.size = CGSize(width: min(fitted.width + 14, label.frame.width), height: fitted.height + 6)
        }

        let areaChanged = weave != appliedArea
        weaveArea = weave
        nativeArea = native
        for (layer, area) in [(weaveFrame, weave), (nativeFrame, native)] {
            layer.path = UIBezierPath(roundedRect: area.insetBy(dx: -10, dy: -10), cornerRadius: 36).cgPath
        }
        nativeContainer.frame = native
        if areaChanged {
            appliedArea = weave
            placeAll()
        }
    }

    /// Puts every panel at its fraction with no spring (a layout change, or the
    /// pinned positions).
    private func placeAll() {
        for (index, piece) in Self.pieces.enumerated() {
            if let pin = pins[piece.name] { fractions[0][index] = pin; fractions[1][index] = pin }
            fractions[0][index] = clamped(fractions[0][index], size: piece.size, in: weaveArea)
            fractions[1][index] = clamped(fractions[1][index], size: piece.size, in: nativeArea)
            if index < springs.count { try? springs[index].jump(to: weaveFrame(index)) }
            nativeGlass[index].frame = nativeLocalFrame(index)
        }
        if UserDefaults.standard.bool(forKey: "lab.drag.latched"), !pins.isEmpty, springs.count == Self.pieces.count {
            // `-lab.drag.latched YES`: the pinned frame as seen by a pair that
            // was merged first (the pill and the round button touching) and was
            // then pulled to the pinned gap, to show the hysteresis.
            var frames = springs.map(\.frame)
            frames[1].origin.x = frames[0].maxX
            let touching = zip(frames, Self.pieces).map { GlassProximityMerge.Outline.panel(frame: $0, cornerRadius: Double($1.corner)) }
            _ = try? tracker.update(touching)
        }
        applyPanels()
    }

    /// A fraction whose panel stays inside `area`.
    private func clamped(_ fraction: CGPoint, size: CGSize, in area: CGRect) -> CGPoint {
        guard area.width > 0, area.height > 0 else { return fraction }
        let minX = size.width / 2 / area.width, minY = size.height / 2 / area.height
        return CGPoint(x: min(max(fraction.x, minX), 1 - minX), y: min(max(fraction.y, minY), 1 - minY))
    }

    private func weaveFrame(_ index: Int) -> CGRect {
        frame(index, fraction: fractions[0][index], in: weaveArea)
    }

    private func nativeLocalFrame(_ index: Int) -> CGRect {
        frame(index, fraction: fractions[1][index], in: CGRect(origin: .zero, size: nativeArea.size))
    }

    private func frame(_ index: Int, fraction: CGPoint, in area: CGRect) -> CGRect {
        let size = Self.pieces[index].size
        return CGRect(
            x: area.minX + fraction.x * area.width - size.width / 2, y: area.minY + fraction.y * area.height - size.height / 2,
            width: size.width, height: size.height
        )
    }

    // MARK: Moving

    /// Moves a panel of both groups to a fraction of its area: GlassWeave's by
    /// the spring (retargeting in flight keeps the velocity), Apple's by a
    /// UIKit spring animation. Reduce Motion goes there at once.
    private func move(_ index: Int, to fraction: CGPoint) {
        guard index < springs.count else { return }
        let size = Self.pieces[index].size
        fractions[0][index] = clamped(fraction, size: size, in: weaveArea)
        fractions[1][index] = clamped(fraction, size: size, in: nativeArea)
        try? springs[index].setTarget(weaveFrame(index))
        moveNative(index)
    }

    private func moveNative(_ index: Int) {
        let glass = nativeGlass[index]
        let frame = nativeLocalFrame(index)
        let change = { glass.frame = frame }
        if reduceMotion {
            change()
        } else {
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: change)
        }
    }

    @objc private func weavePan(_ pan: UIPanGestureRecognizer) {
        guard let button = pan.view else { return }
        drag(pan, index: button.tag, group: 0, raise: button)
    }

    @objc private func nativePan(_ pan: UIPanGestureRecognizer) {
        guard let glass = pan.view else { return }
        drag(pan, index: glass.tag, group: 1, raise: glass)
    }

    private func drag(_ pan: UIPanGestureRecognizer, index: Int, group: Int, raise: UIView) {
        let area = group == 0 ? weaveArea : CGRect(origin: .zero, size: nativeArea.size)
        let size = Self.pieces[index].size
        let key = group * 10 + index
        switch pan.state {
        case .began:
            dragStart[key] = fractions[group][index]
            raise.superview?.bringSubviewToFront(raise)
            if group == 0, activeDrags.insert(key).inserted { surface?.beginInteraction() }
        case .changed:
            guard let start = dragStart[key], area.width > 0 else { return }
            let t = pan.translation(in: view)
            let fraction = clamped(CGPoint(x: start.x + t.x / area.width, y: start.y + t.y / area.height), size: size, in: area)
            fractions[group][index] = fraction
            if group == 0 {
                try? springs[index].setTarget(weaveFrame(index))
            } else {
                moveNative(index)
            }
        case .ended, .cancelled, .failed:
            dragStart[key] = nil
            if group == 0, activeDrags.remove(key) != nil { surface?.endInteraction() }
            scheduleStatus()
        default:
            break
        }
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
        let names = Self.pieces.map(\.name)
        var parts = tracker.pairs.map { pair in
            "\(names[pair.first])+\(names[pair.second]) gap \(String(format: "%.1f", pair.gap)) p \(String(format: "%.2f", pair.progress))\(pair.isMerged ? " merged" : "")"
        }
        parts.append(contentsOf: [
            "panels \(surface.renderer.panels.count)",
            anySpringMoving ? "spring moving" : "spring idle",
            surface.isAnimating ? "clock on" : "clock off",
            "submitted \(submitted)",
            "after settle \(settledMark.map { "+\(submitted - $0)" } ?? "-")",
            "taps \(taps)",
            "drawn " + surface.renderer.drawnVariants.map(\.rawValue).joined(separator: ","),
        ])
        let settings = surface.accessibilitySettings
        if settings.reduceMotion { parts.append("Reduce Motion") }
        if settings.reduceTransparency { parts.append("Reduce Transparency") }
        statusLabel.text = parts.joined(separator: " | ")
    }
}
