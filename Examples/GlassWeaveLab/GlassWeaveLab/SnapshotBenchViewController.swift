import GlassWeave
import GlassWeaveUIKit
import Metal
import UIKit

/// The "Over real UI" page (GW-31): custom glass that bends and frosts a real
/// scrolling `UITableView`, from a static snapshot, beside Apple's live glass.
///
/// - **Top: GlassWeave glass over a snapshot.** A table of colored rows with a
///   capsule of GlassWeave glass over it. The capsule cannot read live pixels, so
///   it shows a **static snapshot** of the table region under it
///   (`UIKitSnapshotSource`), bent at the rim and frosted. The snapshot is
///   refreshed **when scrolling ends** (or by the Refresh button), never every
///   frame; while the list moves the snapshot is stale, so the bar fades out and
///   fades back in with the new one.
/// - **Bottom: `UIGlassEffect`.** The same rows under Apple's glass, which is
///   **live**: it samples what is behind it every frame, so it stays on while
///   the list scrolls. The bottom list follows the top one.
/// - **Status line.** The last snapshot's size, scale, technique and measured
///   main-thread time, and its state (fresh or stale).
///
/// `-lab.snapshot YES` opens it. `-lab.snapshot.offset <pt>` starts the list
/// scrolled; `-lab.snapshot.scrollTo <pt>` scrolls the list there (animated)
/// after a second, so the refresh at the end of scrolling shows;
/// `-lab.snapshot.hold <pt>` moves the list there without ending the scroll,
/// to show the stale state; `-lab.snapshot.frost 0|1` (default 1) frosts the glass;
/// `-lab.snapshot.dark YES|NO` pins the page's appearance;
/// `-lab.snapshot.measure <n>` measures `n` refreshes of three region sizes and
/// prints the result in the status line.
final class SnapshotBenchViewController: UIViewController {
    // MARK: Launch

    static var launchRequested: Bool {
        UserDefaults.standard.bool(forKey: "lab.snapshot")
    }

    /// The laboratory's menu entry, which opens this page over the window.
    static func menuButton(presentedBy presenter: UIViewController, hidden: Bool) -> UIButton {
        let button = UIButton(configuration: .bordered())
        button.configuration?.title = String(localized: "Over real UI")
        button.accessibilityIdentifier = "lab.openSnapshot"
        button.isHidden = hidden
        button.addAction(UIAction { [weak presenter] _ in
            if let presenter { present(from: presenter, animated: true) }
        }, for: .primaryActionTriggered)
        return button
    }

    private static var openedAtLaunch = false

    /// Opens the page once when `-lab.snapshot YES` was given.
    static func presentAtLaunch(from presenter: UIViewController) {
        guard !openedAtLaunch, launchRequested else { return }
        openedAtLaunch = true
        present(from: presenter, animated: false)
    }

    /// Presents the page over the whole window, unless `presenter` already
    /// presents something.
    static func present(from presenter: UIViewController, animated: Bool) {
        guard presenter.presentedViewController == nil else { return }
        let page = SnapshotBenchViewController()
        page.modalPresentationStyle = .fullScreen
        presenter.present(page, animated: animated)
    }

    // MARK: Content

    /// One row of the list: a hue, a symbol, two lines of text.
    private struct Row {
        let title: String
        let detail: String
        let symbol: String
        let hue: CGFloat
    }

    private static let rows: [Row] = {
        let names = [
            ("Amber", "warm resin, slow light", "sun.max.fill", 0.09), ("Fern", "damp leaves, green shade", "leaf.fill", 0.34),
            ("Tide", "salt, glass, a long swell", "water.waves", 0.53), ("Plum", "late dusk over the roofs", "moon.stars.fill", 0.78),
            ("Ember", "last coals in the grate", "flame.fill", 0.02), ("Moss", "quiet stones, soft ground", "tree.fill", 0.26),
            ("Cobalt", "deep water, clear sky", "drop.fill", 0.60), ("Orchid", "petal edges, pale light", "sparkles", 0.88),
            ("Saffron", "dry spice, bright cloth", "star.fill", 0.13), ("Teal", "shallows over white sand", "fish.fill", 0.47),
        ]
        return (0..<40).map { index in
            let base = names[index % names.count]
            return Row(
                title: "\(base.0) \(index + 1)", detail: base.1, symbol: base.2,
                hue: (base.3 + CGFloat(index / names.count) * 0.035).truncatingRemainder(dividingBy: 1)
            )
        }
    }()

    private static let rowHeight: CGFloat = 64
    private static let barHeight: CGFloat = 60

    /// The frost blur in points; `-lab.snapshot.sigma` overrides it.
    private static var frostSigma: Double {
        let value = UserDefaults.standard.double(forKey: "lab.snapshot.sigma")
        return value > 0 ? value : 8
    }

    // MARK: State

    private final class Content: NSObject, UITableViewDataSource {
        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { SnapshotBenchViewController.rows.count }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
            let row = SnapshotBenchViewController.rows[indexPath.row]
            var content = UIListContentConfiguration.subtitleCell()
            content.text = row.title
            content.secondaryText = row.detail
            content.image = UIImage(systemName: row.symbol)
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
            content.textProperties.color = .label
            content.secondaryTextProperties.color = .secondaryLabel
            content.imageProperties.tintColor = .label
            cell.contentConfiguration = content
            let hue = row.hue
            cell.backgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(hue: hue, saturation: 0.62, brightness: 0.46, alpha: 1)
                    : UIColor(hue: hue, saturation: 0.34, brightness: 0.99, alpha: 1)
            }
            cell.selectionStyle = .none
            return cell
        }
    }

    private enum Phase {
        case fresh, stale, unavailable
    }

    private let content = Content()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(configuration: .glass())
    private let weaveCaption = UILabel()
    private let nativeCaption = UILabel()
    private let weaveHost = UIView()
    private let nativeHost = UIView()
    private let leader = UITableView(frame: .zero, style: .plain)
    private let follower = UITableView(frame: .zero, style: .plain)
    private let weaveBar = UIView()
    private let nativeBar = NativeGlassView(configuration: .init(isInteractive: false))
    private let frostControl = UISegmentedControl(items: [String(localized: "Clear"), String(localized: "Frosted")])
    private let appearanceControl = UISegmentedControl(items: [String(localized: "Light"), String(localized: "Dark")])
    private let scrollButton = UIButton(configuration: .bordered())
    private let refreshButton = UIButton(configuration: .bordered())
    private let statusLabel = UILabel()

    private var surface: GlassSurfaceView?
    private var snapshot: UIKitSnapshotSource?
    private var setupFailure: String?
    private var snapshotOffset: CGFloat?
    private var snapshotSize = CGSize.zero
    private var phase = Phase.unavailable
    private var lastReport: UIKitSnapshotSource.Report?
    private var lastFailure: String?
    private var refreshes = 0
    private var submitted = 0
    private var measurement: String?
    private var scrolledDown = false
    private var launchScrollTask: Task<Void, Never>?
    private var statusWidth: CGFloat = 0

    private var frosted: Bool
    private let pinnedAppearance: UIUserInterfaceStyle

    init() {
        let defaults = UserDefaults.standard
        frosted = defaults.object(forKey: "lab.snapshot.frost") == nil ? true : defaults.bool(forKey: "lab.snapshot.frost")
        if defaults.object(forKey: "lab.snapshot.dark") == nil {
            pinnedAppearance = .unspecified
        } else {
            pinnedAppearance = defaults.bool(forKey: "lab.snapshot.dark") ? .dark : .light
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The appearance the page shows: the view's, which the page's override sets
    /// (the controller's own traits do not follow a view override).
    private var isDark: Bool {
        view.traitCollection.userInterfaceStyle == .dark
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.overrideUserInterfaceStyle = pinnedAppearance
        view.backgroundColor = .systemBackground
        if UserDefaults.standard.bool(forKey: "lab.increaseContrast") {
            traitOverrides.accessibilityContrast = .high
        }
        setUpContent()
        setUpRendering()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.appearanceChanged()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutContent()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let defaults = UserDefaults.standard
        let offset = CGFloat(defaults.double(forKey: "lab.snapshot.offset"))
        if offset > 0 { leader.contentOffset = CGPoint(x: 0, y: offset) }
        // The first snapshot, once the rows are on screen.
        refreshSnapshot(afterScreenUpdates: true)
        if let text = defaults.string(forKey: "lab.snapshot.measure"), let count = Int(text), count > 0 {
            Task { @MainActor [weak self] in await self?.runMeasurement(count: min(count, 200)) }
        }
        if let held = Double(defaults.string(forKey: "lab.snapshot.hold") ?? "") {
            // A scroll that never ends, for the capture of the stale state: the
            // offset jumps without an end-of-scrolling event, so no refresh follows.
            launchScrollTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.0))
                guard !Task.isCancelled, let self else { return }
                leader.setContentOffset(CGPoint(x: 0, y: held), animated: false)
            }
        } else if let target = Double(defaults.string(forKey: "lab.snapshot.scrollTo") ?? "") {
            launchScrollTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled, let self else { return }
                scrolledDown = true
                leader.setContentOffset(CGPoint(x: 0, y: target), animated: true)
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        launchScrollTask?.cancel()
    }

    // MARK: Rendering

    private func setUpRendering() {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw UIKitSnapshotError.resourceCreation("a Metal device") }
            guard let queue = device.makeCommandQueue() else { throw UIKitSnapshotError.resourceCreation("a command queue") }
            queue.label = "GlassWeaveLab snapshot"
            let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
            surface.accessibilityIdentifier = "snapshot.surface"
            if let override = LabViewController.accessibilitySettingsOverride {
                surface.accessibilitySettingsSource = .fixed(override)
            }
            // The surface is exactly the capsule: its corners are clipped to the
            // panel's outline, so no pixel of the snapshot shows outside the glass
            // and the live list around it shows through unchanged.
            surface.layer.masksToBounds = true
            surface.layer.cornerCurve = .circular
            surface.renderObserver = { [weak self] outcome in
                guard let self else { return }
                if case .submitted = outcome {
                    submitted += 1
                    updateStatus()
                }
            }
            surface.visibilityHandler = { [weak self] visible in
                if !visible { self?.snapshot?.trim() }
            }
            weaveBar.insertSubview(surface, at: 0)
            self.surface = surface
            snapshot = try UIKitSnapshotSource(renderer: surface.renderer)
        } catch {
            setupFailure = String(describing: error)
        }
        updateStatus()
    }

    private func panelParameters() -> GlassParameters {
        var parameters = RefinedLook.enhancedLens(corner: 999, bezel: 22, thickness: 24, dispersion: 0.2, dark: isDark)
        // The soft shadow comes from the bar's own layer: the surface is clipped
        // to the capsule, so there is no room for the shader's.
        parameters.grounding = .none
        // Presence picks up the backdrop's color with a few soft taps around each
        // pixel. That assumes a smooth backdrop: over real text it draws faint
        // echoes of the lettering. The snapshot already is the backdrop (and the
        // frost its blurred color), so the page turns presence off.
        parameters.lighting.presence = 0
        if frosted {
            // A calm, even frost, no grain: the snapshot's detail softens and its
            // colors stay.
            parameters.frost = GlassFrost(profile: .uniform, sigma: Self.frostSigma, grain: 0, saturation: 1.12, brightness: 1)
        }
        return parameters
    }

    private func applyPanel() {
        guard let surface, surface.bounds.width > 0 else { return }
        do {
            try surface.setPanel(GlassPanel(frame: surface.bounds, parameters: panelParameters()))
        } catch {
            lastFailure = String(describing: error)
        }
    }

    /// Captures the list region under the glass and hands it to the surface. On
    /// demand only: after scrolling ends, after a change of appearance, on a
    /// resize, and from the Refresh button.
    private func refreshSnapshot(afterScreenUpdates: Bool) {
        guard let surface, let snapshot, surface.bounds.width > 0 else { return }
        leader.layoutIfNeeded()
        do {
            let report = try snapshot.refresh(surface, from: leader, afterScreenUpdates: afterScreenUpdates)
            lastReport = report
            lastFailure = nil
            refreshes += 1
            snapshotOffset = leader.contentOffset.y
            snapshotSize = surface.bounds.size
            phase = .fresh
            setBar(visible: true)
        } catch {
            lastFailure = String(describing: error)
            phase = .unavailable
        }
        updateStatus()
    }

    private func appearanceChanged() {
        applyPanel()
        applyColors()
        // The snapshot shows the old appearance until refreshed: that is the
        // contract, so the page refreshes it right away, after the traits settle.
        DispatchQueue.main.async { [weak self] in
            self?.refreshSnapshot(afterScreenUpdates: true)
        }
    }

    // MARK: Build

    private func setUpContent() {
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.text = String(localized: "Over real UI")
        titleLabel.accessibilityTraits.insert(.header)
        closeButton.configuration?.title = String(localized: "Close")
        closeButton.accessibilityIdentifier = "snapshot.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)

        weaveCaption.text = String(localized: "GlassWeave glass over a static snapshot of this list, refreshed when scrolling ends. Not live: the bar fades while the list moves.")
        nativeCaption.text = String(localized: "UIGlassEffect over the same list: live, it follows every frame. The list below mirrors the one above.")
        for label in [weaveCaption, nativeCaption] {
            label.font = .preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.textColor = .secondaryLabel
        }
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel
        statusLabel.accessibilityIdentifier = "snapshot.status"

        for (table, identifier) in [(leader, "snapshot.table"), (follower, "snapshot.table.live")] {
            table.dataSource = content
            table.register(UITableViewCell.self, forCellReuseIdentifier: "row")
            table.rowHeight = Self.rowHeight
            table.separatorStyle = .none
            table.showsVerticalScrollIndicator = false
            table.contentInsetAdjustmentBehavior = .never
            table.backgroundColor = .systemBackground
            table.accessibilityIdentifier = identifier
        }
        leader.delegate = self
        follower.isUserInteractionEnabled = false
        follower.isAccessibilityElement = false
        follower.accessibilityElementsHidden = true

        for host in [weaveHost, nativeHost] {
            host.layer.cornerRadius = 24
            host.layer.cornerCurve = .continuous
            host.clipsToBounds = true
            host.layer.borderWidth = 1
        }
        weaveHost.addSubview(leader)
        nativeHost.addSubview(follower)

        // A soft shadow under GlassWeave's bar (Apple's glass casts its own).
        weaveBar.layer.shadowOffset = CGSize(width: 0, height: 4)
        weaveBar.layer.shadowRadius = 10
        nativeBar.cornerConfiguration = .capsule()
        weaveHost.addSubview(weaveBar)
        nativeHost.addSubview(nativeBar)

        makeBarContent(title: "GlassWeave", detail: String(localized: "snapshot, refreshed on demand"), in: weaveBar, native: false)
        makeBarContent(title: "UIGlassEffect", detail: String(localized: "live, every frame"), in: nativeBar.contentView, native: true)

        frostControl.selectedSegmentIndex = frosted ? 1 : 0
        frostControl.accessibilityIdentifier = "snapshot.frost"
        frostControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            frosted = frostControl.selectedSegmentIndex == 1
            applyPanel()
        }, for: .valueChanged)
        appearanceControl.selectedSegmentIndex = pinnedAppearance == .dark ? 1 : 0
        appearanceControl.accessibilityIdentifier = "snapshot.appearance"
        appearanceControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            view.overrideUserInterfaceStyle = appearanceControl.selectedSegmentIndex == 1 ? .dark : .light
        }, for: .valueChanged)
        scrollButton.configuration?.title = String(localized: "Scroll down")
        scrollButton.accessibilityIdentifier = "snapshot.scroll"
        scrollButton.addAction(UIAction { [weak self] _ in self?.toggleScroll() }, for: .primaryActionTriggered)
        refreshButton.configuration?.title = String(localized: "Refresh snapshot")
        refreshButton.accessibilityIdentifier = "snapshot.refresh"
        refreshButton.addAction(UIAction { [weak self] _ in self?.refreshSnapshot(afterScreenUpdates: true) }, for: .primaryActionTriggered)

        for subview in [titleLabel, closeButton, weaveCaption, weaveHost, nativeCaption, nativeHost, frostControl, appearanceControl, scrollButton, refreshButton, statusLabel] {
            view.addSubview(subview)
        }
        applyColors()
    }

    private func makeBarContent(title: String, detail: String, in container: UIView, native: Bool) {
        let name = UILabel()
        name.text = title
        name.font = .preferredFont(forTextStyle: .headline)
        name.textColor = .label
        let sub = UILabel()
        sub.text = detail
        sub.font = .preferredFont(forTextStyle: .caption1)
        sub.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [name, sub])
        stack.axis = .vertical
        stack.spacing = 1
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])
    }

    private func applyColors() {
        let dark = isDark
        for host in [weaveHost, nativeHost] {
            host.layer.borderColor = UIColor(white: dark ? 1 : 0, alpha: 0.12).cgColor
        }
        weaveBar.layer.shadowColor = UIColor(red: 0.04, green: 0.05, blue: 0.1, alpha: 1).cgColor
        weaveBar.layer.shadowOpacity = dark ? 0.26 : 0.09
    }

    // MARK: Layout

    private var barFrame: CGRect {
        let host = weaveHost.bounds
        let inset: CGFloat = 16
        return CGRect(x: inset, y: (host.height - Self.barHeight) / 2, width: host.width - inset * 2, height: Self.barHeight)
    }

    private func layoutContent() {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let width = min(safe.width - 32, 520)
        let left = safe.midX - width / 2
        titleLabel.frame = CGRect(x: left, y: safe.minY + 4, width: 200, height: 36)
        closeButton.frame = CGRect(x: left + width - 88, y: safe.minY + 4, width: 88, height: 44)
        var y = safe.minY + 52
        // Everything below the title and above the controls and status is shared
        // by the two lists.
        let fixed: CGFloat = 2 * 44 + 2 * 8 + 2 * 36 + 40 + 14 + 8 + 70
        let hostHeight = min(max((safe.height - 52 - fixed) / 2, 150), 240)
        func place(_ caption: UILabel, _ host: UIView) {
            caption.frame = CGRect(x: left, y: y, width: width, height: 40)
            caption.frame.size.height = caption.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            y += caption.frame.height + 6
            host.frame = CGRect(x: left, y: y, width: width, height: hostHeight)
            y += hostHeight + 12
        }
        place(weaveCaption, weaveHost)
        place(nativeCaption, nativeHost)
        frostControl.frame = CGRect(x: left, y: y, width: (width - 10) / 2, height: 32)
        appearanceControl.frame = CGRect(x: left + (width - 10) / 2 + 10, y: y, width: (width - 10) / 2, height: 32)
        y += 40
        scrollButton.frame = CGRect(x: left, y: y, width: (width - 10) / 2, height: 40)
        refreshButton.frame = CGRect(x: left + (width - 10) / 2 + 10, y: y, width: (width - 10) / 2, height: 40)
        y += 48
        statusLabel.frame = CGRect(x: left, y: y, width: width, height: 64)
        statusWidth = width

        for host in [weaveHost, nativeHost] {
            (host === weaveHost ? leader : follower).frame = host.bounds
        }
        let bar = barFrame
        weaveBar.frame = bar
        nativeBar.frame = bar
        weaveBar.layer.shadowPath = UIBezierPath(roundedRect: weaveBar.bounds, cornerRadius: bar.height / 2).cgPath
        if let surface {
            let sizeChanged = surface.frame.size != weaveBar.bounds.size
            surface.frame = weaveBar.bounds
            surface.layer.cornerRadius = bar.height / 2
            applyPanel()
            // A resize invalidates the snapshot: refresh once at the new size.
            if sizeChanged, snapshotSize != .zero { refreshSnapshot(afterScreenUpdates: true) }
        }
        updateStatus()
    }

    // MARK: Scrolling

    private func toggleScroll() {
        scrolledDown.toggle()
        scrollButton.configuration?.title = scrolledDown ? String(localized: "Scroll back") : String(localized: "Scroll down")
        leader.setContentOffset(CGPoint(x: 0, y: scrolledDown ? 232 : 0), animated: true)
    }

    private var reduceMotion: Bool {
        surface?.accessibilitySettings.reduceMotion ?? UIAccessibility.isReduceMotionEnabled
    }

    /// Shows or hides the bar, with a short fade (none under Reduce Motion).
    private func setBar(visible: Bool) {
        let target: CGFloat = visible ? 1 : 0
        guard weaveBar.alpha != target else { return }
        if reduceMotion {
            weaveBar.alpha = target
        } else {
            UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.weaveBar.alpha = target
            }
        }
    }

    private func markStale() {
        guard phase == .fresh else { return }
        phase = .stale
        setBar(visible: false)
        updateStatus()
    }

    /// Scrolling has ended: refresh the snapshot.
    private func scrollingEnded() {
        refreshSnapshot(afterScreenUpdates: true)
    }

    // MARK: Measurement

    /// Measures `count` refreshes of three region sizes on the main thread and
    /// prints the medians: the list cropped to the bar's region, the whole list, and
    /// the whole page (the draw renders the whole view, so the first two cost alike).
    private func runMeasurement(count: Int) async {
        guard let snapshot, let surface else { return }
        try? await Task.sleep(for: .seconds(0.6))
        func stats(_ values: [Double]) -> String {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return "none" }
            return String(format: "median %.1f p95 %.1f max %.1f ms", sorted[sorted.count / 2], sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)], sorted[sorted.count - 1])
        }
        var lines: [String] = []
        let regions: [(String, UIView, CGRect?)] = [
            ("list view, bar region", leader, nil), ("list view, all", leader, leader.bounds), ("page view, all", view, view.bounds),
        ]
        for (name, target, region) in regions {
            var totals: [Double] = [], draws: [Double] = []
            var skipped = 0
            var pixels = ""
            for _ in 0..<count {
                do {
                    let (lease, report) = try snapshot.capture(
                        target, region: region ?? target.convert(surface.bounds, from: surface),
                        scale: surface.traitCollection.displayScale
                    )
                    lease.retire()
                    totals.append(report.totalMilliseconds)
                    draws.append(report.drawMilliseconds)
                    pixels = "\(report.pixelWidth)x\(report.pixelHeight)"
                } catch {
                    skipped += 1
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
            lines.append("\(name) \(pixels): total \(stats(totals)); draw \(stats(draws))\(skipped > 0 ? "; skipped \(skipped)" : "")")
        }
        measurement = "measured \(count) each: " + lines.joined(separator: " | ")
        updateStatus()
    }

    // MARK: Status

    private func updateStatus() {
        var lines: [String] = []
        if let setupFailure {
            lines.append(setupFailure)
        } else {
            var parts: [String] = []
            switch phase {
            case .fresh: parts.append("snapshot fresh")
            case .stale: parts.append("snapshot STALE (scrolling), bar hidden")
            case .unavailable: parts.append("no snapshot")
            }
            if let report = lastReport {
                parts.append("#\(report.frameID) \(report.pixelWidth)x\(report.pixelHeight) px @\(String(format: "%.0f", report.scale))x")
                parts.append("\(report.technique == .drawHierarchy ? "drawHierarchy" : "layer")")
                parts.append(String(format: "%.1f ms (draw %.1f, upload %.1f)%@", report.totalMilliseconds, report.drawMilliseconds, report.uploadMilliseconds, report.exceededBudget ? " OVER BUDGET" : ""))
            }
            parts.append("refreshes \(refreshes)")
            parts.append("frames drawn \(submitted)")
            if let snapshot {
                let pool = snapshot.poolStatistics
                parts.append("textures \(pool.allocations) allocated, \(pool.texturesInUse) in use")
            }
            if let settings = surface?.accessibilitySettings {
                if settings.reduceMotion { parts.append("Reduce Motion") }
                if settings.reduceTransparency { parts.append("Reduce Transparency") }
            }
            lines.append(parts.joined(separator: " | "))
        }
        if let lastFailure { lines.append("refresh failed: \(lastFailure)") }
        if let measurement { lines.append(measurement) }
        statusLabel.text = lines.joined(separator: "\n")
        if statusWidth > 0 {
            let fitted = statusLabel.sizeThatFits(CGSize(width: statusWidth, height: .greatestFiniteMagnitude))
            statusLabel.frame.size = CGSize(width: statusWidth, height: fitted.height + 4)
        }
    }
}

extension SnapshotBenchViewController: UITableViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === leader else { return }
        // Apple's list mirrors this one, offset for offset.
        follower.contentOffset = leader.contentOffset
        if let snapshotOffset, abs(leader.contentOffset.y - snapshotOffset) > 0.5 {
            markStale()
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scrollingEnded() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scrollingEnded()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollingEnded()
    }
}
