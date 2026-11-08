import GlassWeave
import GlassWeaveUIKit
import Metal
import UIKit

/// The single comparison screen. It hosts a labeled native-reference region,
/// a labeled custom region, and a reset action that returns the laboratory
/// to a repeatable starting state.
final class LabViewController: UIViewController {
    /// Counts reset presses so UI tests can confirm the action ran.
    private(set) var resetCount = 0

    private let referenceRegion = LabRegionView(
        title: String(localized: "Native reference"),
        identifier: "lab.referenceRegion"
    )
    private let customRegion = LabRegionView(
        title: String(localized: "Custom GlassWeave"),
        identifier: "lab.customRegion"
    )
    private let regions = UIStackView()
    private let diagnosticsLabel = UILabel()
    private let resetButton = UIButton(configuration: .bordered())

    /// Native mode: genuine Apple glass around a real button, over a simple
    /// moving backdrop. Nothing in this region creates a GlassWeave renderer.
    private let nativeGlass = NativeGlassView()
    private let nativeButton = UIButton(configuration: .plain())
    private let tintControl = UISegmentedControl(items: NativeTint.allCases.map(\.title))
    private let enabledSwitch = UISwitch()
    private var nativeTapCount = 0

    /// The app-owned background producer and the surface presenting it, or
    /// the reason the custom region could not be set up.
    private var custom: Result<(source: PatternSource, surface: GlassSurfaceView), any Error>?
    private var nextFrameID: UInt64 = 1
    private var lastRelease: BackgroundFrameRelease?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        diagnosticsLabel.font = .preferredFont(forTextStyle: .footnote)
        diagnosticsLabel.adjustsFontForContentSizeCategory = true
        diagnosticsLabel.numberOfLines = 0
        diagnosticsLabel.textColor = .secondaryLabel
        diagnosticsLabel.accessibilityIdentifier = "lab.diagnostics"

        resetButton.configuration?.title = String(localized: "Reset")
        resetButton.accessibilityIdentifier = "lab.reset"
        resetButton.addAction(UIAction { [weak self] _ in self?.reset() }, for: .primaryActionTriggered)

        regions.addArrangedSubview(referenceRegion)
        regions.addArrangedSubview(customRegion)
        regions.axis = .vertical
        regions.spacing = 16
        regions.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [regions, diagnosticsLabel, resetButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
        ])

        setUpReferenceRegion()
        setUpCustomRegion()
        reset()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Side by side when the scene is wider than tall, from local bounds.
        let axis: NSLayoutConstraint.Axis = view.bounds.width > view.bounds.height ? .horizontal : .vertical
        if regions.axis != axis {
            regions.axis = axis
        }
    }

    /// Returns every laboratory control to its initial state.
    func reset() {
        resetCount += 1
        resetNativeReference()
        presentNextPatternFrame()
        updateDiagnostics()
    }

    // MARK: Native reference region

    /// The glass tints the laboratory compares.
    enum NativeTint: Int, CaseIterable {
        case none, blue, orange

        var title: String {
            switch self {
            case .none: String(localized: "None")
            case .blue: String(localized: "Blue")
            case .orange: String(localized: "Orange")
            }
        }

        var color: UIColor? {
            switch self {
            case .none: nil
            case .blue: .systemBlue
            case .orange: .systemOrange
            }
        }

        var diagnosticName: String {
            switch self {
            case .none: "none"
            case .blue: "blue"
            case .orange: "orange"
            }
        }
    }

    private func setUpReferenceRegion() {
        let stage = UIView()
        stage.clipsToBounds = true
        stage.layer.cornerRadius = 12
        let stripes = MovingStripesView()
        stripes.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(stripes)

        nativeButton.configuration?.title = String(localized: "Native action")
        nativeButton.configuration?.baseForegroundColor = .label
        nativeButton.accessibilityIdentifier = "lab.nativeButton"
        nativeButton.translatesAutoresizingMaskIntoConstraints = false
        nativeButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            nativeTapCount += 1
            updateDiagnostics()
        }, for: .primaryActionTriggered)

        nativeGlass.cornerConfiguration = .capsule()
        nativeGlass.accessibilityIdentifier = "lab.nativeGlass"
        nativeGlass.translatesAutoresizingMaskIntoConstraints = false
        nativeGlass.contentView.addSubview(nativeButton)
        stage.addSubview(nativeGlass)

        NSLayoutConstraint.activate([
            stripes.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            stripes.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            stripes.topAnchor.constraint(equalTo: stage.topAnchor),
            stripes.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            nativeButton.leadingAnchor.constraint(equalTo: nativeGlass.contentView.leadingAnchor, constant: 20),
            nativeButton.trailingAnchor.constraint(equalTo: nativeGlass.contentView.trailingAnchor, constant: -20),
            nativeButton.topAnchor.constraint(equalTo: nativeGlass.contentView.topAnchor, constant: 8),
            nativeButton.bottomAnchor.constraint(equalTo: nativeGlass.contentView.bottomAnchor, constant: -8),
            nativeGlass.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            nativeGlass.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            nativeGlass.leadingAnchor.constraint(greaterThanOrEqualTo: stage.leadingAnchor, constant: 16),
            nativeGlass.topAnchor.constraint(greaterThanOrEqualTo: stage.topAnchor, constant: 8),
        ])

        tintControl.accessibilityIdentifier = "lab.nativeTint"
        tintControl.addAction(UIAction { [weak self] _ in self?.applyNativeState() }, for: .valueChanged)
        enabledSwitch.accessibilityIdentifier = "lab.nativeEnabled"
        enabledSwitch.accessibilityLabel = String(localized: "Native action enabled")
        enabledSwitch.addAction(UIAction { [weak self] _ in self?.applyNativeState() }, for: .valueChanged)
        let enabledLabel = UILabel()
        enabledLabel.text = String(localized: "Enabled")
        enabledLabel.font = .preferredFont(forTextStyle: .subheadline)
        enabledLabel.adjustsFontForContentSizeCategory = true
        // The switch carries the label for VoiceOver.
        enabledLabel.isAccessibilityElement = false

        let controls = UIStackView(arrangedSubviews: [tintControl, UIView(), enabledLabel, enabledSwitch])
        controls.axis = .horizontal
        controls.spacing = 8
        controls.alignment = .center

        let body = UIStackView(arrangedSubviews: [stage, controls])
        body.axis = .vertical
        body.spacing = 8
        referenceRegion.setBody(body)
    }

    /// Applies the tint and enabled state the controls show. A disabled
    /// control also gets non-interactive glass.
    private func applyNativeState() {
        let tint = NativeTint(rawValue: tintControl.selectedSegmentIndex) ?? .none
        let enabled = enabledSwitch.isOn
        nativeGlass.configuration = NativeGlassView.Configuration(tintColor: tint.color, isInteractive: enabled)
        nativeButton.isEnabled = enabled
        updateDiagnostics()
    }

    /// Restores untinted, enabled, interactive glass and clears the tap count.
    private func resetNativeReference() {
        tintControl.selectedSegmentIndex = NativeTint.none.rawValue
        enabledSwitch.isOn = true
        nativeTapCount = 0
        applyNativeState()
    }

    // MARK: Custom region

    private func setUpCustomRegion() {
        do {
            let source = try PatternSource()
            let surface = GlassSurfaceView(renderer: try BackgroundRenderer(commandQueue: source.queue))
            surface.accessibilityIdentifier = "lab.customSurface"
            surface.renderObserver = { [weak self] _ in self?.updateDiagnostics() }
            customRegion.setBody(surface)
            custom = .success((source, surface))
        } catch {
            let label = UILabel()
            label.text = String(describing: error)
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            customRegion.setBody(label)
            custom = .failure(error)
        }
    }

    /// Hands the surface a newly produced frame. The previous frame's lease
    /// is released once the surface lets go of it and every draw that
    /// sampled it has completed.
    private func presentNextPatternFrame() {
        guard case let .success((source, surface)) = custom else { return }
        let frameID = nextFrameID
        nextFrameID += 1
        do {
            let lease = try source.makeFrame(frameID: frameID) { [weak self] release in
                Task { @MainActor in
                    self?.lastRelease = release
                    self?.updateDiagnostics()
                }
            }
            try surface.setSource(lease)
            // The laboratory hands each frame to one surface only.
            lease.retire()
        } catch {
            custom = .failure(error)
        }
    }

    // MARK: Diagnostics

    private func updateDiagnostics() {
        var lines = [Self.gpuDescription(), "Resets: \(resetCount)"]
        let tint = NativeTint(rawValue: tintControl.selectedSegmentIndex) ?? .none
        lines.append("Native taps: \(nativeTapCount) · tint \(tint.diagnosticName) · \(nativeButton.isEnabled ? "enabled" : "disabled")")
        switch custom {
        case let .success((_, surface)):
            let frame = surface.renderer.currentFrame.map { "frame \($0.frameID)" } ?? "no frame"
            let size = "\(surface.pixelSize.width)×\(surface.pixelSize.height) px"
            let outcome = surface.lastRenderOutcome.map(Self.describe) ?? "not drawn"
            lines.append("Custom: \(frame) · \(size) · \(outcome)")
        case let .failure(error):
            lines.append("Custom unavailable: \(error)")
        case nil:
            break
        }
        if let lastRelease {
            lines.append("Released frame \(lastRelease.frameID): \(lastRelease.completedSubmissions) drawn, \(lastRelease.skippedSubmissions) skipped")
        }
        diagnosticsLabel.text = lines.joined(separator: "\n")
    }

    private static func describe(_ outcome: BackgroundRenderOutcome) -> String {
        switch outcome {
        case let .submitted(frameID): "submitted frame \(frameID)"
        case let .skipped(reason): "skipped (\(reason))"
        }
    }

    private static func gpuDescription() -> String {
        guard let device = MTLCreateSystemDefaultDevice() else { return "No Metal device" }
        let capabilities = RenderCapabilities(device: device)
        let family = capabilities.highestAppleFamily.map { "apple\($0)" } ?? "none"
        return "GPU \(capabilities.deviceName) · Metal 3 \(capabilities.supportsMetal3) · Metal 4 \(capabilities.supportsMetal4) · \(family)"
    }
}

/// A titled, outlined container for one comparison mode.
final class LabRegionView: UIView {
    private let body = UIView()

    init(title: String, identifier: String) {
        super.init(frame: .zero)
        layer.cornerRadius = 16
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.cgColor
        accessibilityIdentifier = identifier

        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            body.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.layer.borderColor = UIColor.separator.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Places `content` in the region below its title, filling the space.
    func setBody(_ content: UIView) {
        body.subviews.forEach { $0.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            content.topAnchor.constraint(equalTo: body.topAnchor),
            content.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
    }
}
