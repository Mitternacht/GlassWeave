import GlassWeave
import GlassWeaveUIKit
import Metal
import UIKit

/// The Apple vs GlassWeave screen (GW-29a, the scaffold): one procedural
/// backdrop, two halves with the same layout, one comparison row per
/// ``VersusCase``.
///
/// - The leading half is Apple's glass: a ``NativeGlassView`` (`UIGlassEffect`)
///   with its one tint, and the GW-14 rim and halo around it for fairness
///   (``EnhancedNativeGlassView``). Its view hierarchy holds the glass views
///   and a plain Metal view for the backdrop; it holds no GlassWeave surface.
///   The half clips its content at the divider (`clipsToBounds`).
/// - The trailing half is GlassWeave's own glass: one `GlassSurfaceView` that
///   spans only that half, so its drawable ends at the divider. That is the
///   clip, in place of a scissor rect: no panel can reach across the divider,
///   and the diagnostics check that none does. The glass panels sit behind
///   native placeholders with native buttons.
/// - Both halves scroll together (two scroll views with one offset), over a
///   backdrop that is a function of the screen position, so the pictures meet
///   at the divider.
///
/// Words state only what the code does or what Apple's public API offers
/// (``VersusCopy``, ``VersusCase``). Native controls carry VoiceOver labels;
/// text sits on dark plates, opaque under Reduce Transparency and Increase
/// Contrast; the interiors stop under Reduce Motion or with the switch off;
/// the layout uses leading and trailing, so it mirrors in right-to-left. The
/// screen draws nothing while nothing changes: the effect clock runs only
/// while an interior moves.
///
/// Launch arguments: `-lab.versus YES` opens it from the laboratory,
/// `-lab.versusAnimate NO` starts with still interiors, `-lab.versusScroll
/// <points>` scrolls it, for captures.
final class VersusViewController: UIViewController {
    private struct Rendering {
        let surface: GlassSurfaceView
        let renderer: VersusBackdropRenderer
        let nativeBackdrop: VersusBackdropView
    }

    private var rendering: Result<Rendering, any Error>?
    /// What the next surface background frame shows, and what the frame on
    /// screen shows.
    private var backdrop = VersusBackdrop()
    private var producedBackdrop: VersusBackdrop?

    private let cases = VersusCase.all

    // MARK: Views

    private let headerBar = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(configuration: .glass())
    private let animateRow = UIStackView()
    private let animateCaption = UILabel()
    private let animateSwitch = UISwitch()
    private let nativeHalf = UIView()
    private let weaveHalf = UIView()
    private let nativeScroll = UIScrollView()
    private let weaveScroll = UIScrollView()
    private let divider = UIView()
    private let footer = UIView()
    private let footerStack = UIStackView()
    private let diagnosticsLabel = UILabel()
    private var nativeRows: [VersusRowView] = []
    private var weaveRows: [VersusRowView] = []
    private var plates: [VersusPlate] = []

    // MARK: State

    private var nativeTaps = 0
    private var weaveTaps = 0
    private var quadsApart = true
    private var appliedLaunchState = false
    private var scrollIsSyncing = false

    // MARK: Launch

    static var launchRequested: Bool {
        UserDefaults.standard.bool(forKey: "lab.versus")
    }

    /// The laboratory's menu entry, which opens this screen over the window.
    static func menuButton(presentedBy presenter: UIViewController, hidden: Bool) -> UIButton {
        let button = UIButton(configuration: .bordered())
        button.configuration?.title = String(localized: "Apple vs GlassWeave")
        button.accessibilityIdentifier = "lab.openVersus"
        button.isHidden = hidden
        button.addAction(UIAction { [weak presenter] _ in
            if let presenter { present(from: presenter, animated: true) }
        }, for: .primaryActionTriggered)
        return button
    }

    /// Presents the screen over the whole window, unless `presenter` already
    /// presents something.
    static func present(from presenter: UIViewController, animated: Bool) {
        guard presenter.presentedViewController == nil else { return }
        let screen = VersusViewController()
        screen.modalPresentationStyle = .fullScreen
        presenter.present(screen, animated: animated)
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        if UserDefaults.standard.bool(forKey: "lab.increaseContrast") {
            // Stands in for the system setting in UI tests, as in the gallery.
            traitOverrides.accessibilityContrast = .high
        }
        setUpRendering()
        setUpLayout()
        applyContentSizeLayout()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.applyContentSizeLayout()
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (self: Self, _) in
            self.updateGeometry()
            self.applyAccessibilityState()
            self.updateDiagnostics()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        applyAccessibilityState()
        updateGeometry()
        updateDiagnostics()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        nativeScroll.layoutIfNeeded()
        weaveScroll.layoutIfNeeded()
        applyLaunchState()
        updateGeometry()
    }

    /// `-lab.versusAnimate NO` and `-lab.versusScroll <points>`, once the
    /// content has its size, for captures.
    private func applyLaunchState() {
        guard !appliedLaunchState, nativeScroll.contentSize.height > 0 else { return }
        appliedLaunchState = true
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "lab.versusAnimate") != nil {
            animateSwitch.isOn = defaults.bool(forKey: "lab.versusAnimate")
        }
        let requested = CGFloat(defaults.double(forKey: "lab.versusScroll"))
        if requested > 0 {
            let limit = max(nativeScroll.contentSize.height - nativeScroll.bounds.height, 0)
            let offset = CGPoint(x: 0, y: min(requested, limit))
            nativeScroll.contentOffset = offset
            weaveScroll.contentOffset = offset
        }
        applyAccessibilityState()
    }

    // MARK: Rendering setup

    private func setUpRendering() {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw VersusFailure.noMetalDevice }
            guard let queue = device.makeCommandQueue() else { throw VersusFailure.noCommandQueue }
            queue.label = "GlassWeaveLab versus"
            let renderer = try VersusBackdropRenderer(device: device)
            let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
            surface.accessibilityIdentifier = "versus.surface"
            if let override = LabViewController.accessibilitySettingsOverride {
                surface.accessibilitySettingsSource = .fixed(override)
            }
            let nativeBackdrop = VersusBackdropView(renderer: renderer)
            rendering = .success(Rendering(surface: surface, renderer: renderer, nativeBackdrop: nativeBackdrop))
            surface.renderObserver = { [weak self] _ in self?.renderDidFinish() }
            surface.visibilityHandler = { [weak self] visible in self?.surfaceVisibilityChanged(visible) }
            surface.accessibilitySettingsHandler = { [weak self] _ in
                self?.applyAccessibilityState()
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

    private enum VersusFailure: Error, CustomStringConvertible {
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
        guard let lease = rendering.renderer.encodeFrame(into: commandBuffer, backdrop: next) else { return nil }
        producedBackdrop = next
        return lease
    }

    // MARK: Layout

    private func setUpLayout() {
        // Header: the title and Close, then the interiors switch.
        headerBar.backgroundColor = .systemBackground
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = VersusCopy.title
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits.insert(.header)
        closeButton.configuration?.image = UIImage(systemName: "xmark")
        closeButton.accessibilityLabel = String(localized: "Close")
        closeButton.accessibilityIdentifier = "versus.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleRow = UIStackView(arrangedSubviews: [titleLabel, closeButton])
        titleRow.alignment = .center
        titleRow.spacing = 12

        animateCaption.text = VersusCopy.animateInterior
        animateCaption.font = .preferredFont(forTextStyle: .subheadline)
        animateCaption.adjustsFontForContentSizeCategory = true
        animateCaption.numberOfLines = 0
        animateCaption.isAccessibilityElement = false
        animateSwitch.isOn = true
        animateSwitch.accessibilityLabel = VersusCopy.animateInterior
        animateSwitch.accessibilityIdentifier = "versus.animate"
        animateSwitch.addAction(UIAction { [weak self] _ in
            self?.updateGeometry()
            self?.updateDiagnostics()
        }, for: .valueChanged)
        animateSwitch.setContentHuggingPriority(.required, for: .horizontal)
        animateRow.addArrangedSubview(animateCaption)
        animateRow.addArrangedSubview(animateSwitch)
        animateRow.spacing = 12
        animateRow.alignment = .center

        let headerStack = UIStackView(arrangedSubviews: [titleRow, animateRow])
        headerStack.axis = .vertical
        headerStack.spacing = 4
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(headerStack)
        view.addSubview(headerBar)

        // Footer: what the hierarchy and the surface show.
        footer.backgroundColor = .systemBackground
        footer.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsLabel.font = .preferredFont(forTextStyle: .caption2)
        diagnosticsLabel.adjustsFontForContentSizeCategory = true
        diagnosticsLabel.numberOfLines = 0
        diagnosticsLabel.textColor = .secondaryLabel
        diagnosticsLabel.accessibilityIdentifier = "versus.diagnostics"
        footerStack.addArrangedSubview(diagnosticsLabel)
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerStack)
        view.addSubview(footer)

        // The halves.
        configureHalf(nativeHalf, label: String(localized: "Apple glass half"), identifier: "versus.nativeHalf")
        configureHalf(weaveHalf, label: String(localized: "GlassWeave glass half"), identifier: "versus.weaveHalf")
        if case let .success(rendering) = rendering {
            pin(rendering.nativeBackdrop, in: nativeHalf)
            pin(rendering.surface, in: weaveHalf)
        } else {
            nativeHalf.backgroundColor = .secondarySystemBackground
            weaveHalf.backgroundColor = .secondarySystemBackground
        }
        buildColumn(.native, scroll: nativeScroll, half: nativeHalf)
        buildColumn(.weave, scroll: weaveScroll, half: weaveHalf)

        // The divider over both halves.
        divider.backgroundColor = UIColor(white: 1, alpha: 0.9)
        divider.layer.shadowColor = UIColor.black.cgColor
        divider.layer.shadowOpacity = 0.35
        divider.layer.shadowRadius = 1.5
        divider.layer.shadowOffset = .zero
        divider.isAccessibilityElement = false
        divider.isUserInteractionEnabled = false
        divider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(divider)

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: view.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerStack.topAnchor.constraint(equalTo: headerBar.safeAreaLayoutGuide.topAnchor, constant: 6),
            headerStack.leadingAnchor.constraint(equalTo: headerBar.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: headerBar.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            headerStack.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: -6),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footerStack.topAnchor.constraint(equalTo: footer.topAnchor, constant: 6),
            footerStack.leadingAnchor.constraint(equalTo: footer.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            footerStack.trailingAnchor.constraint(equalTo: footer.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            footerStack.bottomAnchor.constraint(equalTo: footer.safeAreaLayoutGuide.bottomAnchor, constant: -4),

            nativeHalf.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nativeHalf.trailingAnchor.constraint(equalTo: view.centerXAnchor),
            nativeHalf.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            nativeHalf.bottomAnchor.constraint(equalTo: footer.topAnchor),
            weaveHalf.leadingAnchor.constraint(equalTo: view.centerXAnchor),
            weaveHalf.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            weaveHalf.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            weaveHalf.bottomAnchor.constraint(equalTo: footer.topAnchor),

            divider.widthAnchor.constraint(equalToConstant: 2),
            divider.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            divider.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            divider.bottomAnchor.constraint(equalTo: footer.topAnchor),
        ])
    }

    /// A half clips its content at its edges (the divider among them) and is
    /// one named group for assistive technologies.
    private func configureHalf(_ half: UIView, label: String, identifier: String) {
        half.translatesAutoresizingMaskIntoConstraints = false
        half.clipsToBounds = true
        half.accessibilityContainerType = .semanticGroup
        half.accessibilityLabel = label
        half.accessibilityIdentifier = identifier
        view.addSubview(half)
    }

    private func pin(_ child: UIView, in half: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        half.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: half.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: half.trailingAnchor),
            child.topAnchor.constraint(equalTo: half.topAnchor),
            child.bottomAnchor.constraint(equalTo: half.bottomAnchor),
        ])
    }

    /// One half's scrolling column: its heading plate, then a row per case.
    private func buildColumn(_ side: VersusRowView.Side, scroll: UIScrollView, half: UIView) {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        scroll.delegate = self
        scroll.accessibilityIdentifier = "versus.\(side.identifier).scroll"
        pin(scroll, in: half)

        let heading: VersusPlate
        switch side {
        case .native:
            heading = VersusPlate(lines: [
                .init(text: VersusCopy.nativeHeading, style: .headline, isBold: true),
                .init(text: VersusCopy.nativeDetail, style: .footnote, isBold: false),
                .init(text: VersusCopy.nativeBetter, style: .footnote, isBold: false),
            ], isHeader: true)
        case .weave:
            heading = VersusPlate(lines: [
                .init(text: VersusCopy.weaveHeading, style: .headline, isBold: true),
                .init(text: VersusCopy.weaveDetail, style: .footnote, isBold: false),
                .init(text: VersusCopy.weaveAdds, style: .footnote, isBold: false),
            ], isHeader: true)
        }
        plates.append(heading)
        let rows = cases.map { versusCase in
            VersusRowView(versusCase: versusCase, side: side) { [weak self] in
                guard let self else { return }
                if side == .native { nativeTaps += 1 } else { weaveTaps += 1 }
                updateDiagnostics()
            }
        }
        for row in rows {
            plates.append(row.titlePlate)
            plates.append(row.captionPlate)
        }

        let column = UIStackView(arrangedSubviews: [heading] + rows)
        column.axis = .vertical
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            column.leadingAnchor.constraint(equalTo: half.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: half.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])

        switch side {
        case .native:
            nativeRows = rows
            nativeHeading = heading
        case .weave:
            weaveRows = rows
            weaveHeading = heading
            tieTwins()
        }
    }

    private var nativeHeading: VersusPlate?
    private var weaveHeading: VersusPlate?

    /// Ties the heights of the two halves' matching plates, so both columns
    /// have the same layout and the same content height (and so scroll
    /// together).
    private func tieTwins() {
        var pairs: [(UIView, UIView)] = zip(nativeRows, weaveRows).flatMap { [($0.titlePlate, $1.titlePlate), ($0.captionPlate, $1.captionPlate)] }
        if let nativeHeading, let weaveHeading {
            pairs.append((nativeHeading, weaveHeading))
        }
        for (native, weave) in pairs {
            native.heightAnchor.constraint(equalTo: weave.heightAnchor).isActive = true
        }
    }

    /// At accessibility text sizes the header's switch row stacks and the
    /// footer's diagnostics are left out, so no text is cut off.
    private func applyContentSizeLayout() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        animateRow.axis = large ? .vertical : .horizontal
        animateRow.alignment = large ? .leading : .center
        diagnosticsLabel.isHidden = large
        view.setNeedsLayout()
    }

    // MARK: Accessibility

    private var reduceMotion: Bool {
        if case let .success(rendering) = rendering {
            return rendering.surface.accessibilitySettings.reduceMotion
        }
        return UIAccessibility.isReduceMotionEnabled
    }

    private var reduceTransparency: Bool {
        if case let .success(rendering) = rendering {
            return rendering.surface.accessibilitySettings.reduceTransparency
        }
        return UIAccessibility.isReduceTransparencyEnabled
    }

    /// Whether the interiors move: the switch is on and Reduce Motion is off.
    private var interiorsAnimate: Bool {
        animateSwitch.isOn && !reduceMotion
    }

    /// Plates turn opaque under Reduce Transparency and Increase Contrast; the
    /// interiors switch is off and disabled under Reduce Motion.
    private func applyAccessibilityState() {
        guard isViewLoaded else { return }
        let opaque = reduceTransparency || traitCollection.accessibilityContrast == .high
        plates.forEach { $0.setOpaque(opaque) }
        if reduceMotion {
            animateSwitch.isEnabled = false
            animateSwitch.setOn(false, animated: false)
        } else {
            animateSwitch.isEnabled = true
        }
    }

    // MARK: Geometry

    /// Gives the glass surface its panels (at the placeholders' frames) and
    /// the backdrop its geometry. Called after layout, on scroll, and when
    /// the switch or an accessibility setting changes.
    private func updateGeometry() {
        guard case let .success(rendering) = rendering else { return }
        let surface = rendering.surface
        guard surface.bounds.width > 0, view.bounds.width > 0 else { return }
        let animated = interiorsAnimate
        let dark = traitCollection.userInterfaceStyle == .dark
        // Only panels in view are drawn; the renderer holds a few panels.
        let reach = CGFloat(VersusCase.halo) + 2
        let visible = surface.bounds.insetBy(dx: -reach, dy: -reach)
        var panels: [GlassPanel] = []
        for (index, row) in weaveRows.enumerated() {
            let rect = row.panel.convert(row.panel.bounds, to: surface)
            guard rect.intersects(visible) else { continue }
            panels.append(GlassPanel(frame: rect, parameters: cases[index].weaveParameters(animated: animated, dark: dark)))
        }
        do {
            try surface.setPanels(panels)
        } catch {
            self.rendering = .failure(error)
            return
        }
        quadsApart = Self.quadsAreApart(surface.presentedPanels, pixel: 1 / max(surface.traitCollection.displayScale, 1))

        let screen = view.bounds.size
        let nativeBackdrop = rendering.nativeBackdrop
        let nativeGeometry = (origin: nativeBackdrop.convert(CGPoint.zero, to: view), size: screen)
        if nativeBackdrop.screenGeometry != nativeGeometry {
            nativeBackdrop.screenGeometry = nativeGeometry
        }

        var next = VersusBackdrop()
        next.displayScale = Double(surface.traitCollection.displayScale)
        next.origin = surface.convert(CGPoint.zero, to: view)
        next.screenSize = screen
        next.dark = traitCollection.userInterfaceStyle == .dark
        if next != backdrop {
            backdrop = next
            surface.requestFrame()
        }
    }

    /// Whether no two panels' quads (the panel grown by its halo and one
    /// pixel, `pixel` points, on every side) overlap.
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

    // MARK: Hierarchy check

    /// What a half's view hierarchy holds: `UIGlassEffect` views (a visual
    /// effect view whose effect is Apple's glass) and GlassWeave surfaces.
    private struct HierarchyCount {
        var glassEffectViews = 0
        var glassWeaveSurfaces = 0
    }

    private static func count(in root: UIView) -> HierarchyCount {
        var count = HierarchyCount()
        func walk(_ view: UIView) {
            if let effectView = view as? UIVisualEffectView, effectView.effect is UIGlassEffect {
                count.glassEffectViews += 1
            }
            if view is GlassSurfaceView {
                count.glassWeaveSurfaces += 1
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return count
    }

    /// Whether `half` lies on its own side of the divider and clips what it
    /// holds. The native half is the leading half and the glass half the
    /// trailing half, which is the right half in a left-to-right layout.
    private func halfIsClipped(_ half: UIView, leading: Bool) -> Bool {
        let frame = half.convert(half.bounds, to: view)
        let middle = view.bounds.midX
        let leftToRight = view.effectiveUserInterfaceLayoutDirection == .leftToRight
        let onLeft = leading == leftToRight
        let onItsSide = onLeft ? frame.maxX <= middle + 0.5 : frame.minX >= middle - 0.5
        return half.clipsToBounds && onItsSide
    }

    /// The glass half is clipped at the divider: its surface, and so its
    /// drawable, ends there, and no panel crosses it.
    private func surfaceIsClippedAtDivider(_ surface: GlassSurfaceView) -> Bool {
        guard halfIsClipped(weaveHalf, leading: false) else { return false }
        let frame = surface.convert(surface.bounds, to: view)
        let middle = view.bounds.midX
        let leftToRight = view.effectiveUserInterfaceLayoutDirection == .leftToRight
        let onItsSide = leftToRight ? frame.minX >= middle - 0.5 : frame.maxX <= middle + 0.5
        let crossing = surface.presentedPanels.contains { panel in
            let rect = panel.frame.offsetBy(dx: frame.minX, dy: frame.minY)
            return rect.minX < middle && rect.maxX > middle
        }
        return onItsSide && !crossing
    }

    // MARK: Visibility and diagnostics

    private func surfaceVisibilityChanged(_ visible: Bool) {
        if !visible, case let .success(rendering) = rendering {
            rendering.renderer.trim()
        }
        updateDiagnostics()
    }

    /// While an interior moves, the diagnostics refresh about four times a
    /// second; otherwise after every draw.
    private func renderDidFinish() {
        guard case let .success(rendering) = rendering else { return }
        if !rendering.surface.isAnimating || rendering.surface.frameStatistics.submitted % 15 == 0 {
            updateDiagnostics()
        }
    }

    private func updateDiagnostics() {
        guard isViewLoaded else { return }
        func plural(_ count: Int, _ noun: String) -> String {
            "\(count) \(noun)\(count == 1 ? "" : "s")"
        }
        let native = Self.count(in: nativeHalf)
        let weave = Self.count(in: weaveHalf)
        var lines = [
            "Native half: \(plural(native.glassEffectViews, "UIGlassEffect view")) · \(plural(native.glassWeaveSurfaces, "GlassWeave surface")) · clipped at the divider \(halfIsClipped(nativeHalf, leading: true) ? "yes" : "NO")",
        ]
        switch rendering {
        case let .success(rendering):
            let surface = rendering.surface
            let presented = surface.presentedPanels
            lines.append("GlassWeave half: \(plural(weave.glassWeaveSurfaces, "surface")) · \(presented.count) of \(cases.count) panels in view · \(plural(weave.glassEffectViews, "UIGlassEffect view")) · clipped at the divider \(surfaceIsClippedAtDivider(surface) ? "yes" : "NO") · quads \(quadsApart ? "apart" : "overlap")")
            let settings = surface.accessibilitySettings
            lines.append("Frames: \(surface.frameStatistics.submitted) submitted · effect clock \(surface.isAnimating ? "running" : "stopped") · backdrop \(rendering.renderer.producedCount) produced · taps native \(nativeTaps), GlassWeave \(weaveTaps) · Reduce Motion \(settings.reduceMotion ? "on" : "off") · Reduce Transparency \(settings.reduceTransparency ? "on" : "off")")
        case let .failure(error):
            lines.append("Screen unavailable: \(error)")
        case nil:
            break
        }
        diagnosticsLabel.text = lines.joined(separator: "\n")
    }
}

/// Scrolling one half scrolls the other, and moves the glass with it.
extension VersusViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let other = scrollView === nativeScroll ? weaveScroll : nativeScroll
        if other.contentOffset != scrollView.contentOffset, !scrollIsSyncing {
            scrollIsSyncing = true
            other.contentOffset = scrollView.contentOffset
            scrollIsSyncing = false
        }
        updateGeometry()
    }
}
