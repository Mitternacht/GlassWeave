@_spi(FrostLab) import GlassWeave
import GlassWeaveUIKit
import Metal
import UIKit

/// GW-24a's frost pyramid screen, opened with `-lab.frost YES`.
///
/// A full-screen surface shows a still picture behind one panel whose glow
/// pulses. The renderer is asked for a frost pyramid covering the panel (the
/// glass shader does not sample it yet, so the picture itself does not change),
/// and the screen shows what the pyramid holds: a tile for each of its levels
/// (1/2 to 1/32 resolution, each blurrier than the last) and a map of the
/// blur radius each frost profile gives over a capsule, with the counters
/// that matter: builds, reuses, and the memory the pyramid takes.
///
/// While the glow pulses the same source frame is drawn again and again, so
/// the pyramid is built once and reused: the build counter stays put and the
/// reuse counter climbs. "New source frame" produces a different frame, which
/// builds exactly once more. `-lab.frost.sigma N` sets the blur in points,
/// `-lab.frost.auto YES` makes two new frames by itself, for captures.
final class FrostLabViewController: UIViewController {
    private let surface: GlassSurfaceView?
    private let source: FrostLabSource?
    private let metrics = RenderMetrics()
    private var failure: String?

    private var frameID: UInt64 = 1
    private var sigma = 8.0
    private var atlasBuilds = -1
    private var atlasGeneration = 0

    private let atlasView = UIImageView()
    private var atlasAspect: NSLayoutConstraint?
    private let readout = UILabel()
    private let caption = UILabel()
    private let sigmaControl = UISegmentedControl(items: ["4 pt", "8 pt", "12 pt"])

    private static let panelSize = CGSize(width: 300, height: 140)

    init() {
        var surface: GlassSurfaceView?
        var source: FrostLabSource?
        var failure: String?
        if let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() {
            queue.label = "GlassWeaveLab frost"
            do {
                surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
                source = FrostLabSource(queue: queue)
            } catch {
                failure = String(describing: error)
            }
        } else {
            failure = "No Metal device is available."
        }
        self.surface = surface
        self.source = source
        self.failure = failure
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        guard let surface, let source else {
            readout.text = failure
            readout.numberOfLines = 0
            readout.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(readout)
            NSLayoutConstraint.activate([
                readout.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
                readout.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
                readout.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            ])
            return
        }
        surface.accessibilityIdentifier = "frost.surface"
        surface.renderer.metrics = metrics
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)

        atlasView.contentMode = .scaleAspectFit
        atlasView.backgroundColor = .black
        atlasView.accessibilityIdentifier = "frost.atlas"
        atlasView.translatesAutoresizingMaskIntoConstraints = false

        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabel
        caption.numberOfLines = 0
        caption.text = "Tiles: pyramid levels 0 to N (half resolution down to 1/16 or 1/32), then the blur map of each profile: uniform, clear center, clear rim, vertical ramp (brighter is more blur)."
        readout.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        readout.numberOfLines = 0
        readout.accessibilityIdentifier = "frost.readout"

        sigmaControl.selectedSegmentIndex = 1
        sigmaControl.accessibilityIdentifier = "frost.sigma"
        sigmaControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.sigma = [4.0, 8.0, 12.0][self.sigmaControl.selectedSegmentIndex]
            self.applyFrost()
        }, for: .valueChanged)
        let newFrame = Self.button("New source frame", id: "frost.newframe") { [weak self] in self?.makeNewFrame() }
        let trim = Self.button("Trim", id: "frost.trim") { [weak self] in
            self?.surface?.renderer.trimFrostResources()
            self?.surface?.requestFrame()
        }
        let buttons = UIStackView(arrangedSubviews: [newFrame, trim])
        buttons.distribution = .fillEqually
        buttons.spacing = 8
        let controls = UIStackView(arrangedSubviews: [atlasView, caption, sigmaControl, buttons, readout])
        controls.axis = .vertical
        controls.spacing = 6
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.36),
            controls.topAnchor.constraint(equalTo: surface.bottomAnchor, constant: 6),
            controls.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            controls.bottomAnchor.constraint(lessThanOrEqualTo: safe.bottomAnchor, constant: -8),
        ])

        if let value = UserDefaults.standard.string(forKey: "lab.frost.sigma").flatMap(Double.init) {
            sigma = value
            sigmaControl.selectedSegmentIndex = value <= 4 ? 0 : (value >= 12 ? 2 : 1)
        }
        surface.renderObserver = { [weak self] _ in self?.drawn() }
        do {
            guard let lease = source.makeFrame(frameID: frameID) else { throw FrostLabError.source }
            try surface.setSource(lease)
            lease.retire()
        } catch {
            readout.text = "Source failed: \(error)"
        }
        applyFrost()
        if UserDefaults.standard.bool(forKey: "lab.frost.auto") {
            Task { @MainActor [weak self] in
                for _ in 0..<2 {
                    try? await Task.sleep(for: .seconds(1.2))
                    self?.makeNewFrame()
                }
            }
        }
    }

    private enum FrostLabError: Error { case source }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let surface else { return }
        let bounds = surface.bounds
        guard bounds.width > 0 else { return }
        let size = CGSize(width: min(Self.panelSize.width, bounds.width - 40), height: Self.panelSize.height)
        let frame = CGRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height
        )
        let glow = GlassGlow(
            colors: [
                .init(red: 0.25, green: 0.75, blue: 1, angle: 0),
                .init(red: 1, green: 0.35, blue: 0.85, angle: 0.5),
            ],
            rimWidth: 3, innerGlowRadius: 28, innerGlowIntensity: 0.55,
            haloRadius: 18, haloIntensity: 0.5, pulsePeriod: 1.6, pulseDepth: 0.5
        )
        let parameters = GlassParameters(
            cornerRadius: 32, bezelWidth: 22, refraction: 0.8, edgeHighlight: 0.6,
            tint: GlassTint(red: 0.97, green: 0.98, blue: 1.0, strength: 0.2), glow: glow
        )
        try? surface.setPanel(GlassPanel(frame: frame, parameters: parameters))
        applyFrost()
    }

    /// Asks the renderer for a pyramid over the panel.
    private func applyFrost() {
        guard let surface, let panel = surface.panel else { return }
        try? surface.renderer.setFrost(GlassFrost(sigma: sigma), region: panel.frame, margin: 12)
        surface.requestFrame()
    }

    private func makeNewFrame() {
        guard let surface, let source else { return }
        frameID += 1
        if let lease = source.makeFrame(frameID: frameID) {
            try? surface.setSource(lease)
            lease.retire()
        }
    }

    /// Runs after every draw: refreshes the readout, and the atlas only when
    /// a pyramid was built since the last one.
    private func drawn() {
        guard let surface else { return }
        let counts = metrics.counts
        let statistics = surface.frameStatistics
        let mebibytes = Double(metrics.frostMemoryBytes) / 1_048_576
        readout.text = String(
            format: "builds=%d reuses=%d memoryBytes=%d (%.2f MiB)\nsource frame=%d sigma=%.0f pt  draws=%d submitted=%d skipped=%d",
            counts.pyramidBuilds, counts.pyramidReuses, metrics.frostMemoryBytes, mebibytes,
            Int(frameID), sigma, counts.draws, statistics.submitted, counts.skipped
        )
        guard counts.pyramidBuilds != atlasBuilds, counts.pyramidBuilds > 0 else { return }
        atlasBuilds = counts.pyramidBuilds
        atlasGeneration += 1
        let generation = atlasGeneration
        let renderer = surface.renderer
        Task { @MainActor [weak self] in
            let image = await renderer.frostAtlasImage(tileHeight: 160, columns: 3)
            guard let self, generation == self.atlasGeneration, let image else { return }
            self.atlasView.image = UIImage(cgImage: image)
            // Size the view to the picture, so no black bars surround it.
            self.atlasAspect?.isActive = false
            let aspect = self.atlasView.heightAnchor.constraint(
                equalTo: self.atlasView.widthAnchor, multiplier: CGFloat(image.height) / CGFloat(image.width)
            )
            aspect.isActive = true
            self.atlasAspect = aspect
        }
    }

    private static func button(_ title: String, id: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.bordered()
        configuration.title = title
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = id
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        return button
    }
}
