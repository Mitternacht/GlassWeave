import GlassWeave
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
    private let diagnosticsLabel = UILabel()
    private let resetButton = UIButton(configuration: .bordered())

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

        let regions = UIStackView(arrangedSubviews: [referenceRegion, customRegion])
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
        reset()
    }

    /// Returns every laboratory control to its initial state.
    func reset() {
        resetCount += 1
        diagnosticsLabel.text = Self.diagnosticsText(resetCount: resetCount)
    }

    private static func diagnosticsText(resetCount: Int) -> String {
        let capabilities = MTLCreateSystemDefaultDevice().map(RenderCapabilities.init(device:))
        let gpu: String
        if let capabilities {
            let family = capabilities.highestAppleFamily.map { "apple\($0)" } ?? "none"
            gpu = "GPU \(capabilities.deviceName) · Metal 3 \(capabilities.supportsMetal3) · Metal 4 \(capabilities.supportsMetal4) · \(family)"
        } else {
            gpu = "No Metal device"
        }
        return "\(gpu)\nResets: \(resetCount)"
    }
}

/// A titled, outlined container for one comparison mode.
final class LabRegionView: UIView {
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
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.layer.borderColor = UIColor.separator.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
