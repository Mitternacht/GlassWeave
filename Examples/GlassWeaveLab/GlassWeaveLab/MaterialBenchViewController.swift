import GlassWeave
import GlassWeaveUIKit
import Metal
import UIKit

/// One of the material bench's five procedural backgrounds (GW-21): 8-bit
/// sRGB pages that a glass look is shown over, so it is judged against a
/// known backdrop. `-lab.bench <page>` opens the bench on one; the
/// light-fields demo uses the same pages as its backdrops
/// (`-lab.lightBackdrop <page>`). The shader is `BenchBackgrounds.metal`.
enum BenchPage: Int, CaseIterable {
    /// Bright dots on a 16-point lattice over near-black, for measuring
    /// displacement by centroid.
    case dotGrid
    /// 16-point dark and light cells.
    case checkerboard
    /// Bands of saturated hue running diagonally.
    case ribbons
    /// A graphite wall and floor with a soft spot.
    case charcoal
    /// Warm white with fine grain.
    case paper

    /// The name used on the command line and in accessibility identifiers.
    var identifier: String {
        switch self {
        case .dotGrid: "dots"
        case .checkerboard: "checkerboard"
        case .ribbons: "ribbons"
        case .charcoal: "charcoal"
        case .paper: "paper"
        }
    }

    var title: String {
        switch self {
        case .dotGrid: String(localized: "Dots")
        case .checkerboard: String(localized: "Checkers")
        case .ribbons: String(localized: "Ribbons")
        case .charcoal: String(localized: "Charcoal")
        case .paper: String(localized: "Paper")
        }
    }

    /// Whether white text reads on the page.
    var isDark: Bool {
        self != .paper
    }

    /// The page named by a launch argument value: an identifier or an index.
    static func named(_ value: String?) -> BenchPage? {
        guard let value else { return nil }
        return allCases.first { $0.identifier == value } ?? Int(value).flatMap(BenchPage.init(rawValue:))
    }

    /// From `-lab.bench <page>`, or `nil` when the argument is absent.
    static var fromBenchArgument: BenchPage? {
        named(UserDefaults.standard.string(forKey: "lab.bench"))
    }
}

/// Renders a bench page into pooled textures, on demand, in the command
/// buffer GlassWeave then samples it in (as the gallery's background does).
final class BenchBackground {
    enum Failure: Error, CustomStringConvertible {
        case shaderUnavailable(String)

        var description: String {
            switch self {
            case let .shaderUnavailable(reason): "The bench background shader is unavailable: \(reason)."
            }
        }
    }

    /// The presented frame plus the surface's two frames in flight.
    static let textureLimit = 3

    private let pipeline: any MTLRenderPipelineState
    private let pool: FrameTexturePool
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private var nextFrameID: UInt64 = 1

    init(device: any MTLDevice) throws {
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "bench_background_vertex"),
              let fragment = library.makeFunction(name: "bench_background_fragment")
        else {
            throw Failure.shaderUnavailable("missing bench_background functions")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "GlassWeaveLab bench background"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw Failure.shaderUnavailable(String(describing: error))
        }
        pool = FrameTexturePool(
            device: device,
            descriptor: FrameTexturePool.Descriptor(
                pixelFormat: .bgra8Unorm,
                usage: [.renderTarget, .shaderRead, .pixelFormatView],
                sampledPixelFormat: BackgroundColorConvention.sRGBOpaque.requiredPixelFormat
            ),
            capacity: Self.textureLimit
        )
        start = clock.now
    }

    /// Encodes `page` at the given size into `commandBuffer` and returns its
    /// lease, or `nil` when no texture is free (nothing is encoded then).
    func encodeFrame(
        into commandBuffer: any MTLCommandBuffer, page: BenchPage, pixelSize: (width: Int, height: Int), scale: Double
    ) -> BackgroundFrameLease? {
        guard let pooled = pool.checkout(width: pixelSize.width, height: pixelSize.height) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = pooled.storage
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            pool.returnUnused(pooled)
            return nil
        }
        let frameID = nextFrameID
        nextFrameID += 1
        var parameters = [SIMD4<Float>(
            Float(scale), Float(page.rawValue), Float(Double(pixelSize.width) / scale), Float(Double(pixelSize.height) / scale)
        )]
        encoder.label = "GlassWeaveLab bench background \(frameID)"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&parameters, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let frame = BackgroundFrame(
            texture: pooled.texture,
            frameID: frameID,
            timestamp: clock.now - start,
            colorConvention: .sRGBOpaque,
            readiness: .encoded(in: commandBuffer)
        )
        return pool.lease(frame, using: pooled) { _ in }
    }

    /// Gives free textures back to Metal while the bench is not visible.
    func trim() {
        pool.trim()
    }
}

/// The material bench, the light-fields demo (GW-21), and the lens page
/// (GW-22).
///
/// - **Lens** (`-lab.lens YES`, or the lab's "Thick lens" button): the thick
///   lens of `GlassLens` on a wide pill with an inlaid dome button, a dome
///   marble, a ring, and a fold pair, over a bench page
///   (`-lab.lensBackdrop <page>`, default the dot grid, to see the
///   magnification and the bending; the ribbons show the dispersion).
///
/// - **Bench** (`-lab.bench <page>`): one bench page full screen with a few
///   plain glass panels over it, and a control to switch pages, so a look is
///   shown over a known backdrop.
/// - **Light fields** (`-lab.lightFields YES`, or the lab's "Light fields"
///   button): the inner light of `GlassLight` on four panels: a wide pill
///   with colored light pooled along its bottom edge (orange, pink, magenta,
///   violet, cyan, flowing slowly, the middle clear), an arc light, an orb,
///   and a four-corner field, over a chosen backdrop
///   (`-lab.lightBackdrop <page>`, default charcoal). `-lab.lightTime
///   <seconds>` shows one still moment.
///
/// All glass is one `GlassSurfaceView`; its background frame is produced only
/// when the page or the size changes. The light flows by this screen's own
/// update link, which sets each light's ``GlassLight/timeOffset`` and runs
/// only while something moves: not under Reduce Motion (the surface's policy
/// stills the light, and the link stops), not when hidden, not for a still
/// `-lab.lightTime`.
final class MaterialBenchViewController: UIViewController {
    enum Mode {
        case bench
        case lightFields
        case lens
    }

    /// One demo panel: where it goes (in a layout the controller computes),
    /// its parameters, and a caption.
    private struct Demo {
        var caption: String
        var parameters: GlassParameters
        var frame = CGRect.zero
    }

    private struct Rendering {
        let surface: GlassSurfaceView
        let background: BenchBackground
    }

    let mode: Mode
    private(set) var page: BenchPage
    private var rendering: Result<Rendering, any Error>?
    private var producedKey: String?
    private var demos: [Demo]
    private let titleLabel = UILabel()
    private let closeButton = UIButton(configuration: .glass())
    private let pageControl: UISegmentedControl
    private let pages: [BenchPage]
    private var captionLabels: [UILabel] = []
    private let timeLabel = UILabel()
    private let diagnosticsLabel = UILabel()
    private var link: UIUpdateLink?
    private var startModelTime: Double?
    /// The moment `-lab.lightTime` freezes the light at, or `nil` to flow.
    private let stillTime: Double?

    init(mode: Mode, page: BenchPage) {
        self.mode = mode
        self.page = page
        switch mode {
        case .bench: pages = BenchPage.allCases
        case .lightFields: pages = [.charcoal, .ribbons, .paper]
        case .lens: pages = [.dotGrid, .checkerboard, .ribbons, .charcoal]
        }
        pageControl = UISegmentedControl(items: pages.map(\.title))
        stillTime = UserDefaults.standard.object(forKey: "lab.lightTime") == nil
            ? nil : UserDefaults.standard.double(forKey: "lab.lightTime")
        switch mode {
        case .bench: demos = Self.benchDemos
        case .lightFields: demos = Self.lightDemos(timeOffset: 0)
        case .lens: demos = Self.lensDemos
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Demos

    private static let benchDemos: [Demo] = [
        Demo(caption: "Default", parameters: GlassParameters()),
        Demo(caption: "Strong rim", parameters: GlassParameters(cornerRadius: 36, bezelWidth: 30, refraction: 1, edgeHighlight: 0.8)),
        Demo(caption: "Circle", parameters: GlassParameters(cornerRadius: 999, bezelWidth: 22, refraction: 0.9)),
        Demo(caption: "Tinted", parameters: GlassParameters(
            cornerRadius: 30, bezelWidth: 18, refraction: 0.7,
            tint: GlassTint(red: 0.3, green: 0.4, blue: 0.9, strength: 0.25)
        )),
    ]

    // MARK: Lens demos (GW-22)

    /// The lens page's panels: a thick pill, a dome marble, a ring, and a
    /// fold pair.
    private static let lensDemos: [Demo] = [
        Demo(caption: String(localized: "Thick lens pill: circular bevel, IOR 1.5"), parameters: GlassParameters(
            cornerRadius: 999, bezelWidth: 34, refraction: 0.6, edgeHighlight: 0.6,
            lens: GlassLens(profile: .circular, thickness: 34, indexOfRefraction: 1.5, maximumOffset: 80, allowsFold: true)
        )),
        Demo(caption: String(localized: "Dome"), parameters: GlassParameters(
            cornerRadius: 999, bezelWidth: 60, refraction: 0.6, edgeHighlight: 0.6,
            lens: GlassLens(profile: .dome, thickness: 48, indexOfRefraction: 1.5, maximumOffset: 80)
        )),
        Demo(caption: String(localized: "Ring"), parameters: GlassParameters(
            cornerRadius: 999, bezelWidth: 20, refraction: 0.6, edgeHighlight: 0.6,
            lens: GlassLens(profile: .ring(center: 13, width: 14), thickness: 26, indexOfRefraction: 1.6, maximumOffset: 80, allowsFold: true)
        )),
        Demo(caption: String(localized: "Fold off: magnified, never mirrored"), parameters: GlassParameters(
            cornerRadius: 28, bezelWidth: 32, refraction: 0.6, edgeHighlight: 0.5,
            lens: GlassLens(profile: .squircle(exponent: 3), thickness: 44, indexOfRefraction: 1.8, maximumOffset: 120, allowsFold: false)
        )),
        Demo(caption: String(localized: "Fold on: the edge mirrors"), parameters: GlassParameters(
            cornerRadius: 28, bezelWidth: 32, refraction: 0.6, edgeHighlight: 0.5,
            lens: GlassLens(profile: .squircle(exponent: 3), thickness: 44, indexOfRefraction: 1.8, maximumOffset: 120, allowsFold: true)
        )),
    ]

    private static func stop(_ red: Double, _ green: Double, _ blue: Double) -> GlassLight.Stop {
        GlassLight.Stop(red: red, green: green, blue: blue)
    }

    /// The four light demos. Every light keeps the middle clear except the
    /// orb, which is the point of an orb.
    private static func lightDemos(timeOffset: Double) -> [Demo] {
        let orange = stop(1.0, 0.60, 0.16), pink = stop(1.0, 0.38, 0.82)
        let violet = stop(0.62, 0.44, 1.0), cyan = stop(0.22, 0.88, 1.0)
        let pill = GlassLight(
            emitters: [GlassLight.Emitter(
                placement: .band(angle: 180, reach: 1.2), colors: [orange, pink, violet, cyan],
                intensity: 0.95, flow: 2, drift: 0.25
            )],
            piping: 0.85, timeOffset: timeOffset
        )
        let arc = GlassLight(
            emitters: [GlassLight.Emitter(
                placement: .arc(angle: 225, span: 170, reach: 0.62), colors: [stop(1, 0.78, 0.25), pink, violet],
                intensity: 0.95, flow: 1, drift: 0.4
            )],
            piping: 1, pipingWidth: 6, timeOffset: timeOffset
        )
        let orb = GlassLight(
            emitters: [GlassLight.Emitter(
                placement: .point(x: 0, y: 0.12, radius: 0.78, stretch: 1), colors: [stop(1, 0.96, 0.82), orange, stop(0.85, 0.12, 0.45)],
                intensity: 0.95, flow: 1, drift: 0.45
            )],
            centerFade: 0.1, piping: 0.5, timeOffset: timeOffset
        )
        let field = GlassLight(
            emitters: [GlassLight.Emitter(
                placement: .field(warp: 0.75), colors: [orange, stop(0.92, 0.18, 0.72), cyan, violet],
                intensity: 0.95, flow: 1
            )],
            piping: 0.7, timeOffset: timeOffset
        )
        let base = { (corner: Double, bezel: Double, light: GlassLight) in
            GlassParameters(cornerRadius: corner, bezelWidth: bezel, refraction: 0.55, edgeHighlight: 0.5, light: light)
        }
        return [
            Demo(caption: String(localized: "Band: light pooled along the bottom edge"), parameters: base(999, 18, pill)),
            Demo(caption: String(localized: "Arc"), parameters: base(40, 18, arc)),
            Demo(caption: String(localized: "Orb"), parameters: base(999, 22, orb)),
            Demo(caption: String(localized: "Field: four corners, warped"), parameters: base(34, 18, field)),
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
        updateLink()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        updateLink()
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
            queue.label = "GlassWeaveLab bench"
            let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
            surface.accessibilityIdentifier = "bench.surface"
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
                self?.updateLink()
            }
            surface.accessibilitySettingsHandler = { [weak self] _ in
                self?.updateLink()
                self?.updateDiagnostics()
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
        switch mode {
        case .bench: titleLabel.text = String(localized: "Material bench")
        case .lightFields: titleLabel.text = String(localized: "Light fields")
        case .lens: titleLabel.text = String(localized: "Thick lens")
        }
        titleLabel.accessibilityTraits.insert(.header)
        closeButton.configuration?.title = String(localized: "Close")
        closeButton.accessibilityIdentifier = "bench.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        pageControl.selectedSegmentIndex = pages.firstIndex(of: page) ?? 0
        pageControl.accessibilityIdentifier = "bench.pages"
        pageControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            page = pages[pageControl.selectedSegmentIndex]
            applyPage()
        }, for: .valueChanged)
        for label in [titleLabel, timeLabel, diagnosticsLabel] {
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
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        timeLabel.textAlignment = .center
        timeLabel.text = "00:01"
        timeLabel.isHidden = mode != .lightFields
        timeLabel.isAccessibilityElement = false
        diagnosticsLabel.font = .preferredFont(forTextStyle: .caption2)
        diagnosticsLabel.numberOfLines = 0
        diagnosticsLabel.accessibilityIdentifier = "bench.diagnostics"
        view.addSubview(pageControl)
        view.addSubview(closeButton)
    }

    /// Text and controls to match the page: white on the dark pages.
    private func applyPage() {
        let color: UIColor = page.isDark ? .white : .black
        for label in [titleLabel, timeLabel] + captionLabels {
            label.textColor = color
        }
        diagnosticsLabel.textColor = page.isDark ? UIColor(white: 1, alpha: 0.7) : UIColor(white: 0, alpha: 0.6)
        pageControl.selectedSegmentIndex = pages.firstIndex(of: page) ?? 0
        // A faint scrim behind the text, so it reads over the dots and cells.
        let scrim = page.isDark ? UIColor(white: 0, alpha: 0.55) : UIColor(white: 1, alpha: 0.55)
        for label in [titleLabel, diagnosticsLabel] + captionLabels {
            label.backgroundColor = scrim
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
            label.textAlignment = .center
        }
        pageControl.backgroundColor = scrim
        // The native controls read on the page: light on dark pages.
        let style: UIUserInterfaceStyle = page.isDark ? .dark : .light
        pageControl.overrideUserInterfaceStyle = style
        closeButton.overrideUserInterfaceStyle = style
        surface?.requestFrame()
        updateDiagnostics()
    }

    /// Places the demo panels and labels, and gives the surface its panels.
    private func layoutDemos() {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let margin: CGFloat = 20
        let width = min(safe.width - 2 * margin, 560)
        let left = safe.midX - width / 2
        titleLabel.frame = CGRect(x: left, y: safe.minY + 8, width: width - 96, height: 40)
        closeButton.frame = CGRect(x: left + width - 88, y: safe.minY + 8, width: 88, height: 44)
        pageControl.frame = CGRect(x: left, y: safe.minY + 60, width: width, height: 34)
        var y = safe.minY + 112
        let gap: CGFloat = 12
        let captionHeight: CGFloat = 20
        var frames: [CGRect] = []
        if mode == .lightFields {
            // The pill, an arc and an orb side by side, and the field.
            let pillHeight: CGFloat = 88
            frames.append(CGRect(x: left, y: y, width: width, height: pillHeight))
            timeLabel.frame = frames[0]
            y += pillHeight + captionHeight + gap + 10
            let side = (width - gap) / 2
            frames.append(CGRect(x: left, y: y, width: side, height: side))
            frames.append(CGRect(x: left + side + gap, y: y, width: side, height: side))
            y += side + captionHeight + gap + 10
            frames.append(CGRect(x: left, y: y, width: width, height: min(160, max(safe.maxY - y - 70, 110))))
        } else if mode == .lens {
            // The pill, then a dome and a ring, then the fold pair.
            let pillHeight: CGFloat = 104
            frames.append(CGRect(x: left, y: y, width: width, height: pillHeight))
            y += pillHeight + captionHeight + gap + 10
            let side = min((width - gap) / 2, 130)
            frames.append(CGRect(x: left, y: y, width: side, height: side))
            frames.append(CGRect(x: left + width - side, y: y, width: side, height: side))
            y += side + captionHeight + gap + 10
            let half = (width - gap) / 2
            let foldHeight = min(110, max(safe.maxY - y - 90, 80))
            frames.append(CGRect(x: left, y: y, width: half, height: foldHeight))
            frames.append(CGRect(x: left + half + gap, y: y, width: half, height: foldHeight))
        } else {
            let pillHeight: CGFloat = 84
            frames.append(CGRect(x: left, y: y, width: width, height: pillHeight))
            y += pillHeight + captionHeight + gap + 10
            frames.append(CGRect(x: left, y: y, width: width, height: 96))
            y += 96 + captionHeight + gap + 10
            let side = (width - gap) / 2
            frames.append(CGRect(x: left, y: y, width: min(side, 150), height: min(side, 150)))
            frames.append(CGRect(x: left + side + gap, y: y, width: side, height: min(side, 150)))
        }
        for index in demos.indices {
            demos[index].frame = frames[index]
            captionLabels[index].frame = CGRect(
                x: frames[index].minX + 4, y: frames[index].maxY + 4, width: frames[index].width - 8, height: captionHeight + 14
            )
        }
        diagnosticsLabel.frame = CGRect(x: left, y: safe.maxY - 36, width: width, height: 32)
        // Hug the text, so the scrim is no wider than it.
        for label in [titleLabel, diagnosticsLabel] + captionLabels {
            let fitted = label.sizeThatFits(CGSize(width: label.frame.width, height: .greatestFiniteMagnitude))
            label.frame.size = CGSize(width: min(fitted.width + 14, label.frame.width), height: min(fitted.height + 6, label.frame.height))
        }
        applyPanels(elapsed: currentElapsed)
        // The panels are in place, so the surface can say whether they move.
        updateLink()
        updateDiagnostics()
    }

    private var currentElapsed = 0.0

    /// Gives the surface the demo panels with their light at `elapsed`
    /// seconds past the still time (or the start).
    private func applyPanels(elapsed: Double) {
        currentElapsed = elapsed
        let base = stillTime ?? 0
        let panels = demos.map { demo -> GlassPanel in
            var parameters = demo.parameters
            parameters.light.timeOffset = base + elapsed
            // Screened light does not show on white: paint it on the paper.
            if mode == .lightFields {
                parameters.light.composite = page.isDark ? .light : .paint
                // Smoky glass on the dark and colorful pages, so light shows
                // over any of them.
                parameters.tint = page.isDark ? GlassTint(red: 0.03, green: 0.03, blue: 0.06, strength: 0.5) : .none
            }
            return GlassPanel(frame: demo.frame, parameters: parameters)
        }
        try? surface?.setPanels(panels)
    }

    // MARK: Motion

    /// Whether the demo's lights should move now: light fields only, not
    /// still, visible, and not under Reduce Motion.
    private var shouldFlow: Bool {
        guard mode == .lightFields, stillTime == nil, let surface, surface.isVisible else { return false }
        return !surface.accessibilitySettings.reduceMotion && surface.presentedPanels.contains { $0.parameters.light.isAnimated }
    }

    private func updateLink() {
        if shouldFlow {
            guard link == nil else { return }
            let newLink = UIUpdateLink(view: view) { [weak self] _, info in
                self?.tick(modelTime: info.modelTime)
            }
            newLink.requiresContinuousUpdates = true
            newLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            newLink.isEnabled = true
            startModelTime = nil
            bankedElapsed = currentElapsed
            link = newLink
        } else if let link {
            link.isEnabled = false
            self.link = nil
        }
    }

    private func tick(modelTime: Double) {
        let start = startModelTime ?? modelTime
        startModelTime = start
        applyPanels(elapsed: bankedElapsed + modelTime - start)
    }

    /// Elapsed seconds from earlier running periods, so a pause does not jump
    /// the light.
    private var bankedElapsed = 0.0

    private func updateDiagnostics() {
        guard let surface else {
            if case let .failure(error) = rendering { diagnosticsLabel.text = String(describing: error) }
            return
        }
        let settings = surface.accessibilitySettings
        var text = "\(page.identifier)"
        if mode == .lightFields {
            text += " | light: \(surface.presentedPanels.filter { $0.parameters.light.isVisible }.count)/\(demos.count) drawn"
            text += settings.reduceMotion ? " | still" : (stillTime == nil ? " | flowing" : " | t=\(stillTime ?? 0)s")
        }
        diagnosticsLabel.text = text
    }
}
