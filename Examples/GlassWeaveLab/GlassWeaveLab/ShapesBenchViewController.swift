import GlassWeave
import GlassWeaveUIKit
import Metal
import UIKit

/// The shapes page (GW-26): glass that is not a rounded rectangle. An ellipse,
/// a squircle, and two blobs of different forms (a pebble and a wobbling
/// triple), each with a glow, an inner light, a thick lens and the light model,
/// so every effect can be seen hugging an organic outline.
///
/// `-lab.shapes YES` opens it; `-lab.shapesBackdrop <page>` picks the bench
/// page behind it (default the charcoal wall); `-lab.shapesTime <seconds>` freezes the
/// wobble at one moment. All glass is one `GlassSurfaceView`. The wobble runs by
/// the surface's own effect clock (``GlassParameters/isAnimated`` includes the
/// shape), which runs only while something moves: not under Reduce Motion
/// (the surface's policy stills the wobble), not when hidden. A still
/// `-lab.shapesTime` pauses the clock (``GlassSurfaceView/isEffectClockPaused``)
/// and sets each blob's ``GlassBlob/Wobble/timeOffset``. The diagnostics
/// line reports whether any two panels' quads overlap (rule 10 of the optics
/// study); it must read `none`.
final class ShapesBenchViewController: UIViewController {
    /// One panel: its parameters, its place in the layout, and a caption.
    private struct Demo {
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
    private var captionLabels: [UILabel] = []
    private let diagnosticsLabel = UILabel()
    /// The moment `-lab.shapesTime` freezes the wobble at, or `nil` to move.
    private let stillTime: Double?

    init(page: BenchPage) {
        self.page = page
        stillTime = UserDefaults.standard.object(forKey: "lab.shapesTime") == nil
            ? nil : UserDefaults.standard.double(forKey: "lab.shapesTime")
        demos = Self.makeDemos()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Demos

    private static func stop(_ red: Double, _ green: Double, _ blue: Double) -> GlassLight.Stop {
        GlassLight.Stop(red: red, green: green, blue: blue)
    }

    private static func glowStop(_ red: Double, _ green: Double, _ blue: Double, _ angle: Double) -> GlassGlow.ColorStop {
        GlassGlow.ColorStop(red: red, green: green, blue: blue, angle: angle)
    }

    /// The glass every shape shares: smoky, thick, lit from the upper left,
    /// with a glow rim and halo in the shape's own colors and the inner light
    /// pooled where it belongs.
    private static func look(
        shape: GlassShape, bezel: Double, glow: [GlassGlow.ColorStop], light: GlassLight, thickness: Double = 30
    ) -> GlassParameters {
        GlassParameters(
            cornerRadius: 999, bezelWidth: bezel, refraction: 0.55, edgeHighlight: 0.35,
            tint: GlassTint(red: 0.03, green: 0.03, blue: 0.06, strength: 0.3),
            glow: GlassGlow(
                colors: glow, rimWidth: 2.5, rimSoftness: 5, innerGlowRadius: 26, innerGlowIntensity: 0.5,
                lightAngle: 315, directionality: 0.55, haloRadius: 9, haloIntensity: 0.5
            ),
            light: light,
            lens: GlassLens(
                profile: .squircle(exponent: 3), thickness: thickness, indexOfRefraction: 1.5, maximumOffset: 60,
                allowsFold: true, dispersion: 0.7, dispersionTaps: .sixTap
            ),
            lighting: GlassLighting(
                key: GlassLighting.Light(azimuth: 315, elevation: 52, intensity: 1, size: 0.3),
                environment: .studioDark, finish: .dielectric,
                fresnel: 0.85, specular: 0.85, reflection: 0.9, bloom: 0.45, bloomWidth: 6
            ),
            shape: shape
        )
    }

    private static func makeDemos() -> [Demo] {
        let orange = stop(1, 0.6, 0.16), pink = stop(1, 0.38, 0.82)
        let violet = stop(0.62, 0.44, 1), cyan = stop(0.22, 0.88, 1)
        // The blobs' coordinates are frame units: 1 is half the frame's shorter
        // side, so they scale with the frame.
        let pebble = GlassBlob(
            primitives: [
                .circle(center: CGPoint(x: -0.30, y: 0.12), radius: 0.62),
                .circle(center: CGPoint(x: 0.36, y: -0.14), radius: 0.52),
                .capsule(from: CGPoint(x: -0.1, y: 0.55), to: CGPoint(x: 0.5, y: 0.42), radius: 0.3),
            ],
            smoothness: 0.5, wobble: GlassBlob.Wobble(amplitude: 0.03, speed: 0.7)
        )
        let triple = GlassBlob(
            primitives: [
                .circle(center: CGPoint(x: -1.35, y: 0.05), radius: 0.78),
                .circle(center: CGPoint(x: -0.1, y: -0.22), radius: 0.6),
                .circle(center: CGPoint(x: 1.25, y: 0.1), radius: 0.72),
                .box(center: CGPoint(x: 0.55, y: 0.35), halfSize: CGSize(width: 0.55, height: 0.3), cornerRadius: 0.25, rotation: -14),
            ],
            smoothness: 0.6, wobble: GlassBlob.Wobble(amplitude: 0.035, speed: 1)
        )
        return [
            Demo(caption: String(localized: "Ellipse: rim, halo and pooled light follow the oval"), parameters: look(
                shape: .ellipse, bezel: 34,
                glow: [glowStop(1, 0.55, 0.2, 0), glowStop(1, 0.3, 0.7, 180)],
                light: GlassLight(
                    emitters: [GlassLight.Emitter(placement: .band(angle: 180, reach: 1.1), colors: [orange, pink, violet, cyan], intensity: 0.95, flow: 2, drift: 0.25)],
                    piping: 0.85
                )
            )),
            Demo(caption: String(localized: "Squircle, exponent 4"), parameters: look(
                shape: .squircle, bezel: 30,
                glow: [glowStop(0.25, 0.85, 1, 0), glowStop(0.65, 0.35, 1, 180)],
                light: GlassLight(
                    emitters: [GlassLight.Emitter(placement: .point(x: 0, y: 0.25, radius: 0.8, stretch: 1), colors: [stop(0.9, 1, 1), cyan, violet], intensity: 0.95, flow: 1, drift: 0.4)],
                    centerFade: 0.15, piping: 0.5
                )
            )),
            Demo(caption: String(localized: "Pebble blob: smooth union of three parts"), parameters: look(
                shape: .blob(pebble), bezel: 30,
                glow: [glowStop(1, 0.62, 0.15, 0), glowStop(1, 0.35, 0.1, 200)],
                light: GlassLight(
                    emitters: [GlassLight.Emitter(placement: .band(angle: 170, reach: 1.0), colors: [stop(1, 0.78, 0.25), orange, pink], intensity: 0.95, flow: 1, drift: 0.4)],
                    piping: 1, pipingWidth: 6
                )
            )),
            Demo(caption: String(localized: "Wobbling triple with a tilted box: necks stay smooth"), parameters: look(
                shape: .blob(triple), bezel: 26,
                glow: [glowStop(1, 0.35, 0.75, 0), glowStop(0.3, 0.8, 1, 180)],
                light: GlassLight(
                    emitters: [GlassLight.Emitter(placement: .band(angle: 180, reach: 0.9), colors: [pink, violet, cyan], intensity: 0.95, flow: 1.5, drift: 0.3)],
                    piping: 0.8
                ), thickness: 26
            )),
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
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        applyPage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutDemos()
    }

    // MARK: Rendering

    private func setUpRendering() {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw BenchBackground.Failure.shaderUnavailable("no Metal device") }
            guard let queue = device.makeCommandQueue() else { throw BenchBackground.Failure.shaderUnavailable("no command queue") }
            queue.label = "GlassWeaveLab shapes"
            let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
            surface.accessibilityIdentifier = "shapes.surface"
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
                self?.updateDiagnostics()
            }
            // A still `-lab.shapesTime` holds the surface's effect clock; the
            // wobble's `timeOffset` then names the moment shown.
            surface.isEffectClockPaused = stillTime != nil
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

    /// The background for the next draw, or `nil` when the frame on screen
    /// already shows it.
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
        titleLabel.text = String(localized: "Shapes")
        titleLabel.accessibilityTraits.insert(.header)
        closeButton.configuration?.title = String(localized: "Close")
        closeButton.accessibilityIdentifier = "shapes.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        diagnosticsLabel.font = .preferredFont(forTextStyle: .caption2)
        diagnosticsLabel.numberOfLines = 0
        diagnosticsLabel.accessibilityIdentifier = "shapes.diagnostics"
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
        view.addSubview(closeButton)
    }

    /// Text and controls to match the page: white on the dark pages.
    private func applyPage() {
        let color: UIColor = page.isDark ? .white : .black
        for label in [titleLabel] + captionLabels {
            label.textColor = color
        }
        diagnosticsLabel.textColor = page.isDark ? UIColor(white: 1, alpha: 0.7) : UIColor(white: 0, alpha: 0.6)
        let scrim = page.isDark ? UIColor(white: 0, alpha: 0.55) : UIColor(white: 1, alpha: 0.55)
        for label in [titleLabel, diagnosticsLabel] + captionLabels {
            label.backgroundColor = scrim
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
            label.textAlignment = .center
        }
        closeButton.overrideUserInterfaceStyle = page.isDark ? .dark : .light
        surface?.requestFrame()
        updateDiagnostics()
    }

    /// Places the panels and captions and gives the surface its panels: the
    /// ellipse across the top, the squircle and the pebble side by side, and
    /// the wide triple below. Quads (the outline's box grown by the halo) are
    /// kept apart by the gaps.
    private func layoutDemos() {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let margin: CGFloat = 20
        let width = min(safe.width - 2 * margin, 640)
        let left = safe.midX - width / 2
        titleLabel.frame = CGRect(x: left, y: safe.minY + 4, width: width - 96, height: 36)
        closeButton.frame = CGRect(x: left + width - 88, y: safe.minY + 4, width: 88, height: 44)
        let captionHeight: CGFloat = 20
        let rowGap: CGFloat = 14
        let columnGap: CGFloat = 30
        // Heights follow the room: the three rows share what is left after the
        // header, the captions and the diagnostics line.
        let available = safe.height - 60 - 36 - 3 * (captionHeight + 14 + rowGap)
        let side = min((width - columnGap) / 2, available * 0.34)
        let ellipseHeight = min(width * 0.46, available * 0.32)
        let tripleHeight = max(available - side - ellipseHeight, 110)
        var y = safe.minY + 56
        var frames: [CGRect] = []
        frames.append(CGRect(x: left, y: y, width: width, height: ellipseHeight))
        y += ellipseHeight + captionHeight + 14 + rowGap
        frames.append(CGRect(x: left, y: y, width: side, height: side))
        frames.append(CGRect(x: left + width - side, y: y, width: side, height: side))
        y += side + captionHeight + 14 + rowGap
        frames.append(CGRect(x: left, y: y, width: width, height: min(tripleHeight, width * 0.46)))
        for index in demos.indices {
            demos[index].frame = frames[index]
            captionLabels[index].frame = CGRect(
                x: frames[index].minX + 4, y: frames[index].maxY + 14, width: frames[index].width - 8, height: captionHeight + 14
            )
        }
        diagnosticsLabel.frame = CGRect(x: left, y: safe.maxY - 36, width: width, height: 32)
        // Hug the text, so the scrim is no wider than it.
        for label in [titleLabel, diagnosticsLabel] + captionLabels {
            let fitted = label.sizeThatFits(CGSize(width: label.frame.width, height: .greatestFiniteMagnitude))
            label.frame.size = CGSize(width: min(fitted.width + 14, label.frame.width), height: min(fitted.height + 6, label.frame.height))
        }
        applyPanels()
        updateDiagnostics()
    }

    /// Gives the surface the panels. The wobble and the light move by the
    /// surface's own effect clock; only a still `-lab.shapesTime` sets the
    /// moment, as the `timeOffset` of each.
    private func applyPanels() {
        let base = stillTime ?? 0
        let panels = demos.map { demo -> GlassPanel in
            var parameters = demo.parameters
            parameters.light.timeOffset = base
            if case var .blob(blob) = parameters.shape {
                blob.wobble.timeOffset = base
                parameters.shape = .blob(blob)
            }
            return GlassPanel(frame: demo.frame, parameters: parameters)
        }
        try? surface?.setPanels(panels)
    }

    // MARK: Diagnostics

    /// The pairs of presented panels whose quads (the outline's bounding box
    /// grown by one point and the glow's halo) share area: rule 10 says none.
    private func overlappingQuads(_ panels: [GlassPanel]) -> [(Int, Int)] {
        let quads = panels.map { panel in
            panel.shapeBounds.insetBy(dx: -(1 + panel.parameters.glow.haloRadius), dy: -(1 + panel.parameters.glow.haloRadius))
        }
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
        let moving = surface.presentedPanels.filter { $0.parameters.shape.isAnimated }.count
        text += settings.reduceMotion ? " | still (Reduce Motion)" : (stillTime == nil ? " | wobbling \(moving)" : " | t=\(stillTime ?? 0)s")
        diagnosticsLabel.text = text
    }
}
