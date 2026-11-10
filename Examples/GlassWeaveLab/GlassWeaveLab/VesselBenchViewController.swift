import GlassWeave
import GlassWeaveUIKit
import Metal
import UIKit

/// The liquid vessels page (GW-28): glass that holds a glowing liquid or gel.
///
/// - **Ember vessel**: a dark, smoky, thick glass pebble (a GW-26 blob) with the
///   refined rim light, holding a glowing orange gel (its own blob) with layered
///   inner sheets, restrained bright edges, a thin line in the glass wall, and a
///   few tiny bubbles, on a near-black stage.
/// - **A second, smaller vessel** in a cool blue-green.
/// - **A level vessel** (`.level` fill) that sloshes when the native "Nudge"
///   button is pressed: a damped spring (``GlassFillSlosh``) the lab steps with
///   a display link until it settles, then stops.
///
/// `-lab.vessel YES` opens it. `-lab.vesselNudge <seconds>` nudges the level
/// vessel at launch and shows the surface that many seconds after the nudge
/// (a still frame, for captures). All glass is one `GlassSurfaceView`; the
/// gel's wobble and the bubbles move by the surface's own effect clock, which
/// runs only while something moves (not under Reduce Motion, not when hidden).
/// The diagnostics line reports whether any two panels' quads overlap; it must
/// read `none`.
final class VesselBenchViewController: UIViewController {
    private enum Vessel: Int, CaseIterable {
        case ember, teal, level
    }

    private struct Demo {
        var vessel: Vessel
        var caption: String
        var parameters: GlassParameters
        var frame = CGRect.zero
    }

    private struct Rendering {
        let surface: GlassSurfaceView
        let background: BenchBackground
    }

    private let page: BenchPage
    private var rendering: Result<Rendering, any Error>?
    private var producedKey: String?
    private var demos: [Demo]
    private let titleLabel = UILabel()
    private let closeButton = UIButton(configuration: .glass())
    private let nudgeButton = UIButton(configuration: .glass())
    private var captionLabels: [UILabel] = []
    private let diagnosticsLabel = UILabel()
    private var slosh = GlassFillSlosh(period: 0.9, dampingRatio: 0.2)
    private var displayLink: CADisplayLink?
    /// From `-lab.vesselNudge`: seconds after the launch nudge to show, or `nil`.
    private let stillNudge: Double?

    init(page: BenchPage) {
        self.page = page
        let defaults = UserDefaults.standard
        stillNudge = defaults.object(forKey: "lab.vesselNudge") == nil ? nil : defaults.double(forKey: "lab.vesselNudge")
        demos = Self.makeDemos()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Demos

    private static func color(_ red: Double, _ green: Double, _ blue: Double) -> GlassFill.Color {
        GlassFill.Color(red: red, green: green, blue: blue)
    }

    /// Clear, thick glass with the refined thin rim light: a clean outline and
    /// a nearly clear body, so the liquid is the only color (see `VesselLook`).
    private static func shell(bezel: Double, thickness: Double, corner: Double = 999) -> GlassParameters {
        VesselLook.shell(corner: corner, bezel: bezel, thickness: thickness)
    }

    private static func makeDemos() -> [Demo] {
        // The shell: a river pebble, a smooth union of a wide rounded box and a
        // circle. Coordinates are frame units (1 is half the frame's shorter side).
        let pebble = GlassBlob(
            primitives: [
                .box(center: CGPoint(x: 0.04, y: 0.02), halfSize: CGSize(width: 1.00, height: 0.80), cornerRadius: 0.60, rotation: -3),
                .circle(center: CGPoint(x: -0.40, y: -0.06), radius: 0.86),
            ],
            smoothness: 0.35
        )
        var ember = shell(bezel: 34, thickness: 30)
        ember.shape = .blob(pebble)
        ember.fill = VesselLook.gel(
            .blob(GlassBlob(
                primitives: [
                    .circle(center: CGPoint(x: -0.34, y: 0.04), radius: 0.60),
                    .circle(center: CGPoint(x: 0.36, y: -0.06), radius: 0.52),
                    .capsule(from: CGPoint(x: -0.50, y: 0.40), to: CGPoint(x: 0.50, y: 0.34), radius: 0.32),
                ],
                smoothness: 0.6, wobble: GlassBlob.Wobble(amplitude: 0.010, speed: 0.5)
            )),
            wall: 6, folds: 0, bubbles: 4, seed: 7
        )

        let drop = GlassBlob(
            primitives: [
                .circle(center: CGPoint(x: 0, y: 0.18), radius: 0.80),
                .capsule(from: CGPoint(x: 0, y: -0.28), to: CGPoint(x: 0, y: 0.1), radius: 0.62),
            ],
            smoothness: 0.5
        )
        var teal = shell(bezel: 24, thickness: 24)
        teal.shape = .blob(drop)
        teal.fill = VesselLook.gel(
            .blob(GlassBlob(
                primitives: [
                    .circle(center: CGPoint(x: 0, y: 0.16), radius: 0.56),
                    .circle(center: CGPoint(x: 0.1, y: -0.24), radius: 0.36),
                ],
                smoothness: 0.5, wobble: GlassBlob.Wobble(amplitude: 0.010, speed: 0.5)
            )),
            colors: [color(0.01, 0.20, 0.22), color(0.05, 0.52, 0.50), color(0.22, 0.74, 0.66)],
            wall: 5, folds: 0, bubbles: 3, seed: 21
        )

        var level = shell(bezel: 22, thickness: 22, corner: 38)
        level.fill = VesselLook.level(
            0.55, colors: [color(0.30, 0.03, 0.13), color(0.78, 0.13, 0.32), color(0.96, 0.40, 0.50)],
            bubbles: 3, seed: 33, amplitude: 0.3
        )
        return [
            Demo(vessel: .ember, caption: String(localized: "Ember vessel: clear glass, a calm luminous gel pooled along the wall and a few tiny bubbles"), parameters: ember),
            Demo(vessel: .teal, caption: String(localized: "A second hue, cool blue-green"), parameters: teal),
            Demo(vessel: .level, caption: String(localized: "Level fill: nudge it and the surface sloshes, then settles"), parameters: level),
        ]
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
        if let stillNudge {
            // A still capture: nudge now and show the surface `stillNudge` seconds later.
            try? slosh.nudge(velocity: -900)
            try? slosh.advance(by: stillNudge)
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        applyPage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutDemos()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopSlosh()
    }

    // MARK: Rendering

    private func setUpRendering() {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw BenchBackground.Failure.shaderUnavailable("no Metal device") }
            guard let queue = device.makeCommandQueue() else { throw BenchBackground.Failure.shaderUnavailable("no command queue") }
            queue.label = "GlassWeaveLab vessels"
            let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
            surface.accessibilityIdentifier = "vessel.surface"
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
                self?.applyPanels()
                self?.updateDiagnostics()
            }
            // A still nudge capture holds the effect clock too.
            surface.isEffectClockPaused = stillNudge != nil
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
        let key = "\(page.rawValue) \(pixelSize.width)x\(pixelSize.height)"
        if key == producedKey, rendering.surface.renderer.currentFrame != nil { return nil }
        let scale = Double(traitCollection.displayScale)
        guard let lease = rendering.background.encodeFrame(into: commandBuffer, page: page, pixelSize: pixelSize, scale: scale) else {
            return nil
        }
        producedKey = key
        return lease
    }

    // MARK: Content

    private func setUpContent() {
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.text = String(localized: "Liquid vessels")
        titleLabel.accessibilityTraits.insert(.header)
        closeButton.configuration?.title = String(localized: "Close")
        closeButton.accessibilityIdentifier = "vessel.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        nudgeButton.configuration?.title = String(localized: "Nudge")
        nudgeButton.accessibilityIdentifier = "vessel.nudge"
        nudgeButton.addAction(UIAction { [weak self] _ in self?.nudge() }, for: .primaryActionTriggered)
        diagnosticsLabel.font = .preferredFont(forTextStyle: .caption2)
        diagnosticsLabel.numberOfLines = 0
        diagnosticsLabel.accessibilityIdentifier = "vessel.diagnostics"
        for label in [titleLabel, diagnosticsLabel] {
            label.translatesAutoresizingMaskIntoConstraints = true
            view.addSubview(label)
        }
        for demo in demos {
            let label = UILabel()
            label.font = .preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 2
            label.text = demo.caption
            view.addSubview(label)
            captionLabels.append(label)
        }
        view.addSubview(nudgeButton)
        view.addSubview(closeButton)
    }

    private func applyPage() {
        for label in [titleLabel] + captionLabels {
            label.textColor = .white
        }
        diagnosticsLabel.textColor = UIColor(white: 1, alpha: 0.7)
        for label in [titleLabel, diagnosticsLabel] + captionLabels {
            label.backgroundColor = UIColor(white: 0, alpha: 0.55)
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
            label.textAlignment = .center
        }
        closeButton.overrideUserInterfaceStyle = .dark
        nudgeButton.overrideUserInterfaceStyle = .dark
        surface?.requestFrame()
        updateDiagnostics()
    }

    /// The ember vessel across the top; the second hue and the level vessel
    /// side by side below it, with the Nudge button under the level vessel.
    private func layoutDemos() {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let margin: CGFloat = 20
        let width = min(safe.width - 2 * margin, 620)
        let left = safe.midX - width / 2
        titleLabel.frame = CGRect(x: left, y: safe.minY + 4, width: width - 96, height: 36)
        closeButton.frame = CGRect(x: left + width - 88, y: safe.minY + 4, width: 88, height: 44)
        let captionHeight: CGFloat = 36
        let gap: CGFloat = 12
        let columnGap: CGFloat = 26
        let header: CGFloat = 56
        let footer: CGFloat = 40
        let nudgeHeight: CGFloat = 44
        let emberHeight = min(width * 0.84, (safe.height - header - footer) * 0.46)
        let rowHeight = max(safe.height - header - footer - emberHeight - 2 * (captionHeight + gap) - nudgeHeight - gap, 120)
        let columnWidth = (width - columnGap) / 2
        var y = safe.minY + header
        var frames: [CGRect] = []
        frames.append(CGRect(x: left + (width - emberHeight * 1.12) / 2, y: y, width: emberHeight * 1.12, height: emberHeight))
        y += emberHeight + captionHeight + gap
        frames.append(CGRect(x: left + (columnWidth - min(columnWidth, rowHeight * 0.85)) / 2, y: y, width: min(columnWidth, rowHeight * 0.85), height: rowHeight))
        frames.append(CGRect(x: left + columnWidth + columnGap + (columnWidth - min(columnWidth, rowHeight * 0.7)) / 2, y: y, width: min(columnWidth, rowHeight * 0.7), height: rowHeight))
        for index in demos.indices {
            demos[index].frame = frames[index]
            captionLabels[index].frame = CGRect(
                x: index == 0 ? left : frames[index].minX - 8, y: frames[index].maxY + 6,
                width: index == 0 ? width : frames[index].width + 16, height: captionHeight
            )
        }
        let levelFrame = frames[Vessel.level.rawValue]
        nudgeButton.frame = CGRect(x: levelFrame.midX - 52, y: levelFrame.maxY + captionHeight + gap, width: 104, height: nudgeHeight)
        diagnosticsLabel.frame = CGRect(x: left, y: safe.maxY - 34, width: width, height: 30)
        for label in [titleLabel, diagnosticsLabel] + captionLabels {
            let fitted = label.sizeThatFits(CGSize(width: label.frame.width, height: .greatestFiniteMagnitude))
            label.frame.size = CGSize(width: min(fitted.width + 14, label.frame.width), height: min(fitted.height + 6, label.frame.height))
        }
        applyPanels()
        updateDiagnostics()
    }

    private func applyPanels() {
        let panels = demos.map { demo -> GlassPanel in
            var parameters = demo.parameters
            if demo.vessel == .level {
                parameters.fill.region = .level(level: 0.55, tilt: slosh.tilt)
                // A swinging surface ripples; a still one does not.
                parameters.fill.surface.waveAmplitude = 0.3 + 2.0 * slosh.agitation
            }
            return GlassPanel(frame: demo.frame, parameters: parameters)
        }
        try? surface?.setPanels(panels)
    }

    // MARK: Slosh

    private func nudge() {
        // An app that honors Reduce Motion does not slosh the liquid.
        if surface?.accessibilitySettings.reduceMotion == true { return }
        try? slosh.nudge(velocity: -900)
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(sloshTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func sloshTick(_ link: CADisplayLink) {
        try? slosh.advance(by: link.targetTimestamp - link.timestamp)
        applyPanels()
        if slosh.isSettled { stopSlosh() }
    }

    private func stopSlosh() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: Diagnostics

    private func overlappingQuads(_ panels: [GlassPanel]) -> [(Int, Int)] {
        let quads = panels.map { $0.shapeBounds.insetBy(dx: -(1 + $0.parameters.glow.haloRadius), dy: -(1 + $0.parameters.glow.haloRadius)) }
        var pairs: [(Int, Int)] = []
        for first in quads.indices {
            for second in quads.indices where second > first {
                let shared = quads[first].intersection(quads[second])
                if !shared.isNull, shared.width > 0, shared.height > 0 { pairs.append((first, second)) }
            }
        }
        return pairs
    }

    private func updateDiagnostics() {
        guard let surface else {
            if case let .failure(error) = rendering { diagnosticsLabel.text = String(describing: error) }
            return
        }
        let settings = surface.accessibilitySettings
        let overlaps = overlappingQuads(surface.presentedPanels)
        var text = "\(page.identifier) | quads overlap: \(overlaps.isEmpty ? "none" : overlaps.map { "\($0.0)-\($0.1)" }.joined(separator: ","))"
        text += " | tilt \(Int(slosh.tilt.rounded()))\u{00B0}"
        if settings.reduceMotion { text += " | still (Reduce Motion)" }
        if settings.reduceTransparency { text += " | opaque fill (Reduce Transparency)" }
        diagnosticsLabel.text = text
    }
}
