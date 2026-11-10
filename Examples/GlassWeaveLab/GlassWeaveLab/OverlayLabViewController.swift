import GlassWeave
import GlassWeaveUIKit
import Metal
import UIKit

/// The overlay page (GW-30): GlassWeave glass drawn over live UIKit content.
///
/// A native, scrolling `UITableView` fills the page. Over it sit one
/// `GlassSurfaceView` made with a renderer in `GlassRenderer.Mode.overlay` (a
/// transparent surface: no background pass, premultiplied alpha, alpha 0 outside
/// every panel) holding two panels, and Apple's own `UIGlassEffect` as a twin:
///
/// - **GlassWeave bar.** A clear bar with a veil of tint, a thin crisp rim, a
///   soft shadow and an edge light, composited by Core Animation over the rows
///   as they scroll. The surface is not redrawn while the list scrolls (the
///   "frames" counter in the status line stays put): the compositor does it.
/// - **UIGlassEffect twin.** The same size and shape in Apple's glass, which
///   bends and frosts whatever scrolls under it.
/// - **GlassWeave capsule.** A capsule with colored light pooled along its
///   bottom edge and a halo, over the same list.
///
/// The honest label: an overlay cannot bend or frost the content behind it,
/// because the surface cannot read the pixels behind it. Apple's glass can.
///
/// `-lab.overlay YES` opens it. `-lab.overlay.offset <points>` sets the list's
/// scroll offset (for captures at fixed offsets). `-lab.overlay.auto YES` scrolls
/// the list slowly up and down by itself (a live demonstration).
/// `-lab.appearance light|dark` picks the page's appearance; `-lab.reduceTransparency YES`,
/// `-lab.increaseContrast YES` and `-lab.reduceMotion YES` apply those policies.
final class OverlayLabViewController: UIViewController {
    static var launchRequested: Bool {
        UserDefaults.standard.bool(forKey: "lab.overlay")
    }

    static func menuButton(presentedBy presenter: UIViewController, hidden: Bool) -> UIButton {
        let button = UIButton(configuration: .bordered())
        button.configuration?.title = String(localized: "Overlay")
        button.accessibilityIdentifier = "lab.openOverlay"
        button.isHidden = hidden
        button.addAction(UIAction { [weak presenter] _ in
            if let presenter { present(from: presenter, animated: true) }
        }, for: .primaryActionTriggered)
        return button
    }

    static func present(from presenter: UIViewController, animated: Bool) {
        guard presenter.presentedViewController == nil else { return }
        let screen = OverlayLabViewController()
        screen.modalPresentationStyle = .fullScreen
        presenter.present(screen, animated: animated)
    }

    // MARK: State

    private let tableView = UITableView(frame: .zero, style: .plain)
    /// An opaque band behind the title and the note: the rows scroll under the
    /// glass, not under the words.
    private let headerBand = UIView()
    private var insetTop: CGFloat = 0
    private var surface: GlassSurfaceView?
    private let titleLabel = UILabel()
    private let noteLabel = UILabel()
    private let closeButton = UIButton(configuration: .glass())
    private let weaveTitle = UILabel()
    private let nativeBar = NativeGlassView()
    private let nativeTitle = UILabel()
    private let composeButton = UIButton(configuration: .plain())
    private let statusLabel = UILabel()

    /// `-lab.overlay.probe YES`: black, mid-gray and white stripes behind one
    /// panel that adds a saturated orange light and nothing else (premultiplied
    /// color above its alpha), to read back how Core Animation composites it.
    private let probing = UserDefaults.standard.bool(forKey: "lab.overlay.probe")
    private var stripes: [UIView] = []
    private var weaveBar = CGRect.zero
    private var capsule = CGRect.zero
    private var submitted = 0
    private var scrollLink: CADisplayLink?
    private var appliedOffset = false

    private static let rowCount = 140

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        if UserDefaults.standard.bool(forKey: "lab.increaseContrast") {
            traitOverrides.accessibilityContrast = .high
        }
        setUpList()
        if probing { setUpStripes() }
        setUpSurface()
        setUpContent()
    }

    private func setUpStripes() {
        tableView.isHidden = true
        for color in [UIColor.black, UIColor(white: 0.5, alpha: 1), UIColor.white] {
            let stripe = UIView()
            stripe.backgroundColor = color
            view.addSubview(stripe)
            stripes.append(stripe)
        }
    }

    /// The probe panel: no tint, no rim, only a flat orange light along the top edge.
    private static func probeParameters() -> GlassParameters {
        var parameters = GlassParameters(cornerRadius: 12, bezelWidth: 8, refraction: 0, edgeHighlight: 0, tint: GlassTint(red: 1, green: 1, blue: 1, strength: 0))
        parameters.light = GlassLight(
            emitters: [GlassLight.Emitter(placement: .band(angle: 0, reach: 1.6), colors: [GlassLight.Stop(red: 1.0, green: 0.35, blue: 0.1)], intensity: 1)],
            centerFade: 0, piping: 0
        )
        parameters.dither = .triangular
        return parameters
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutContent()
        applyOffsetOnce()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if UserDefaults.standard.bool(forKey: "lab.overlay.auto"), !UIAccessibility.isReduceMotionEnabled,
           UserDefaults.standard.object(forKey: "lab.reduceMotion") == nil || !UserDefaults.standard.bool(forKey: "lab.reduceMotion") {
            let link = CADisplayLink(target: ScrollDriver(self), selector: #selector(ScrollDriver.tick(_:)))
            link.add(to: .main, forMode: .common)
            scrollLink = link
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scrollLink?.invalidate()
        scrollLink = nil
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle { updatePanels() }
    }

    // MARK: Live content

    private func setUpList() {
        tableView.dataSource = self
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 64, bottom: 0, right: 0)
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.accessibilityIdentifier = "overlay.list"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        headerBand.backgroundColor = .systemBackground
        view.addSubview(headerBand)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// The offset `-lab.overlay.offset` asks for, applied once the list has its size.
    private func applyOffsetOnce() {
        guard !appliedOffset, tableView.bounds.height > 0, insetTop > 0 else { return }
        appliedOffset = true
        let defaults = UserDefaults.standard
        let offset = defaults.object(forKey: "lab.overlay.offset") == nil ? 0 : defaults.double(forKey: "lab.overlay.offset")
        tableView.setContentOffset(CGPoint(x: 0, y: offset - insetTop), animated: false)
    }

    /// Moves the list by a slow sine, down and up, on the display's own clock.
    fileprivate func scrollTick(_ link: CADisplayLink) {
        let travel = min(tableView.contentSize.height - tableView.bounds.height, 1400)
        guard travel > 0 else { return }
        let phase = (1 - cos(link.timestamp * 2 * .pi / 14)) / 2
        tableView.contentOffset = CGPoint(x: 0, y: phase * travel - insetTop)
    }

    private final class ScrollDriver: NSObject {
        weak var page: OverlayLabViewController?
        init(_ page: OverlayLabViewController) { self.page = page }
        @objc func tick(_ link: CADisplayLink) { page?.scrollTick(link) }
    }

    // MARK: Glass

    private var isDark: Bool { traitCollection.userInterfaceStyle == .dark }

    /// The bar: a clear body with a veil of the page's own color (an overlay
    /// cannot frost, so the veil keeps its label legible over text), the refined
    /// clean rim and a soft shadow.
    private static func barParameters(dark: Bool) -> GlassParameters {
        var parameters = RefinedLook.enhancedPanel(corner: 22, bezel: 14, dark: dark)
        parameters.tint = dark
            ? GlassTint(red: 0.10, green: 0.11, blue: 0.14, strength: 0.74)
            : GlassTint(red: 0.98, green: 0.98, blue: 1.0, strength: 0.80)
        return parameters
    }

    /// The capsule: a lighter veil, colored light pooled along the bottom edge
    /// and a halo of the same colors.
    private static func capsuleParameters(dark: Bool) -> GlassParameters {
        var parameters = RefinedLook.enhancedPanel(corner: 999, bezel: 20, dark: dark)
        parameters.tint = dark
            ? GlassTint(red: 0.10, green: 0.11, blue: 0.14, strength: 0.42)
            : GlassTint(red: 0.98, green: 0.98, blue: 1.0, strength: 0.50)
        let orange = GlassLight.Stop(red: 1.0, green: 0.62, blue: 0.30)
        let pink = GlassLight.Stop(red: 0.96, green: 0.46, blue: 0.72)
        let violet = GlassLight.Stop(red: 0.62, green: 0.50, blue: 0.96)
        // Still by default: the surface is then drawn once and not again while
        // the list scrolls; `-lab.overlay.flow YES` lets the light drift slowly.
        let flows = UserDefaults.standard.bool(forKey: "lab.overlay.flow")
        parameters.light = GlassLight(
            emitters: [GlassLight.Emitter(placement: .band(angle: 180, reach: 0.9), colors: [orange, pink, violet], intensity: dark ? 0.62 : 0.70, flow: flows ? 1 : 0, drift: flows ? 0.2 : 0)],
            composite: dark ? .light : .paint, piping: 0.35
        )
        parameters.glow = GlassGlow(
            colors: [
                .init(red: 1.0, green: 0.60, blue: 0.40, angle: 180),
                .init(red: 0.62, green: 0.52, blue: 0.98, angle: 0),
            ],
            rimWidth: 1.2, rimSoftness: 2, rimIntensity: 0.45,
            innerGlowRadius: 0, innerGlowIntensity: 0,
            lightAngle: 180, directionality: 0.7,
            haloRadius: 20, haloIntensity: dark ? 0.36 : 0.45
        )
        return parameters
    }

    private func setUpSurface() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let renderer = try? GlassRenderer(commandQueue: queue, mode: .overlay)
        else { return }
        queue.label = "GlassWeaveLab overlay"
        let surface = GlassSurfaceView(renderer: renderer)
        surface.accessibilityIdentifier = "overlay.surface"
        surface.translatesAutoresizingMaskIntoConstraints = false
        if let override = LabViewController.accessibilitySettingsOverride {
            surface.accessibilitySettingsSource = .fixed(override)
        }
        surface.renderObserver = { [weak self] outcome in
            guard let self else { return }
            if case .submitted = outcome { self.submitted += 1 }
            self.updateStatus()
        }
        view.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.surface = surface
    }

    private func updatePanels() {
        guard let surface else { return }
        if probing {
            try? surface.setPanels([GlassPanel(frame: CGRect(x: 0, y: 200, width: view.bounds.width, height: 300), parameters: Self.probeParameters())])
            return
        }
        let dark = isDark
        try? surface.setPanels([
            GlassPanel(frame: weaveBar, parameters: Self.barParameters(dark: dark)),
            GlassPanel(frame: capsule, parameters: Self.capsuleParameters(dark: dark)),
        ])
    }

    // MARK: Content

    private func setUpContent() {
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.text = String(localized: "Overlay")
        titleLabel.accessibilityTraits.insert(.header)

        noteLabel.font = .preferredFont(forTextStyle: .footnote)
        noteLabel.adjustsFontForContentSizeCategory = true
        noteLabel.numberOfLines = 0
        noteLabel.text = String(localized: "GlassWeave's overlay (the first bar and the capsule) tints, lights and shades live content behind it. It cannot bend or frost it, because it cannot read it. UIGlassEffect (the second bar) can.")
        noteLabel.textColor = .secondaryLabel

        closeButton.configuration?.title = String(localized: "Close")
        closeButton.accessibilityIdentifier = "overlay.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)

        style(weaveTitle, text: String(localized: "GlassWeave overlay"), textStyle: .subheadline, weight: .semibold)
        style(nativeTitle, text: String(localized: "UIGlassEffect"), textStyle: .subheadline, weight: .semibold)
        nativeBar.cornerConfiguration = .corners(radius: .fixed(22))
        nativeBar.accessibilityIdentifier = "overlay.native"
        nativeBar.contentView.addSubview(nativeTitle)

        composeButton.configuration?.title = String(localized: "Compose")
        composeButton.configuration?.image = UIImage(systemName: "square.and.pencil")
        composeButton.configuration?.imagePadding = 6
        composeButton.configuration?.baseForegroundColor = .label
        composeButton.accessibilityIdentifier = "overlay.compose"

        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.88)
        statusLabel.layer.cornerRadius = 8
        statusLabel.layer.masksToBounds = true
        statusLabel.accessibilityIdentifier = "overlay.status"

        for subview in [weaveTitle, nativeBar, composeButton, titleLabel, noteLabel, closeButton, statusLabel] {
            view.addSubview(subview)
        }
        if probing {
            for hidden in [weaveTitle, nativeBar, composeButton, noteLabel, headerBand] { hidden.isHidden = true }
        }
        updateStatus()
    }

    private func style(_ label: UILabel, text: String, textStyle: UIFont.TextStyle, weight: UIFont.Weight) {
        label.text = text
        label.font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: textStyle).pointSize, weight: weight)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = textStyle == .caption1 ? .secondaryLabel : .label
        label.textAlignment = .center
    }

    private func layoutContent() {
        let safe = view.safeAreaInsets
        let width = view.bounds.width
        let margin: CGFloat = 16
        let barWidth = min(width - 2 * margin, 520)
        let barX = (width - barWidth) / 2
        let barHeight: CGFloat = 62

        let closeSize = closeButton.sizeThatFits(CGSize(width: 200, height: 44))
        closeButton.frame = CGRect(x: width - margin - max(closeSize.width, 44), y: safe.top + 4, width: max(closeSize.width, 44), height: 44)
        titleLabel.frame = CGRect(x: margin, y: safe.top + 8, width: closeButton.frame.minX - 2 * margin, height: 36)
        let noteSize = noteLabel.sizeThatFits(CGSize(width: barWidth, height: .greatestFiniteMagnitude))
        noteLabel.frame = CGRect(x: barX, y: closeButton.frame.maxY + 4, width: barWidth, height: noteSize.height)
        headerBand.frame = CGRect(x: 0, y: 0, width: width, height: noteLabel.frame.maxY + 10)
        if abs(insetTop - headerBand.frame.height) > 0.5 {
            insetTop = headerBand.frame.height
            tableView.contentInset = UIEdgeInsets(top: insetTop, left: 0, bottom: 0, right: 0)
            tableView.verticalScrollIndicatorInsets = UIEdgeInsets(top: insetTop, left: 0, bottom: 0, right: 0)
        }

        weaveBar = CGRect(x: barX, y: headerBand.frame.maxY + 22, width: barWidth, height: barHeight)
        let nativeFrame = CGRect(x: barX, y: weaveBar.maxY + 14, width: barWidth, height: barHeight)
        nativeBar.frame = nativeFrame
        let capsuleWidth: CGFloat = 244
        let capsuleHeight: CGFloat = 70
        let statusHeight: CGFloat = 34
        let statusFrame = CGRect(x: barX, y: view.bounds.height - safe.bottom - statusHeight - 6, width: barWidth, height: statusHeight)
        statusLabel.frame = statusFrame
        capsule = CGRect(
            x: (width - capsuleWidth) / 2, y: statusFrame.minY - 40 - capsuleHeight, width: capsuleWidth, height: capsuleHeight
        )

        // The bars' words sit on the glass as native labels.
        weaveTitle.frame = CGRect(x: weaveBar.minX + 12, y: weaveBar.midY - 11, width: weaveBar.width - 24, height: 22)
        nativeTitle.frame = CGRect(x: 12, y: nativeFrame.height / 2 - 11, width: nativeFrame.width - 24, height: 22)
        composeButton.frame = capsule.insetBy(dx: 16, dy: 10)
        for (index, stripe) in stripes.enumerated() {
            let third = width / 3
            stripe.frame = CGRect(x: third * CGFloat(index), y: 0, width: third, height: view.bounds.height)
        }
        updatePanels()
    }

    private func updateStatus() {
        let policy = surface?.accessibilitySettings
        var text = "overlay surface · frames drawn \(submitted) · panels \(surface?.presentedPanels.count ?? 0)"
        if let policy, policy.reduceTransparency { text += " · Reduce Transparency: opaque body" }
        if traitCollection.accessibilityContrast == .high { text += " · Increase Contrast" }
        statusLabel.text = text
    }
}

// MARK: - Rows

extension OverlayLabViewController: UITableViewDataSource {
    private static let titles = [
        "Quarterly planning notes", "Design review moved", "Lunch with Priya", "Flight to Lisbon", "Invoice 2046 is overdue",
        "Weekend hike, Saturday", "Record store pickup", "Dentist at 09:30", "New album from the quartet", "Book club: chapter nine",
        "Renew the passport", "Kitchen tiles, samples", "Swim lessons for Noor", "Birthday card for Anselm", "Garden: tomatoes need staking",
    ]
    private static let details = [
        "Tuesday 14:30, the large room with the long window", "Wednesday, after the standup, bring the prototypes",
        "A table for two is booked at the place by the canal", "Gate B22, boarding closes forty minutes before departure",
        "Net thirty, please send the receipt when it clears", "Meet at the trailhead by eight, bring water and the red jacket",
        "The reissue is in, the clerk is holding it behind the counter", "Floss, and ask about the retainer again",
    ]
    private static let palette: [UIColor] = [.systemOrange, .systemPink, .systemPurple, .systemTeal, .systemBlue, .systemGreen, .systemIndigo, .systemRed]

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Self.rowCount
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        let row = indexPath.row
        content.text = "\(Self.titles[row % Self.titles.count]) \(row + 1)"
        content.secondaryText = Self.details[(row * 3) % Self.details.count]
        content.textProperties.font = .systemFont(ofSize: 17, weight: .semibold)
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = UIImage(systemName: "circle.fill")
        content.imageProperties.tintColor = Self.palette[row % Self.palette.count]
        content.imageProperties.maximumSize = CGSize(width: 30, height: 30)
        content.imageToTextPadding = 16
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        cell.isAccessibilityElement = true
        return cell
    }
}
