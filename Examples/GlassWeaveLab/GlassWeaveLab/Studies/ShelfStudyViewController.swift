import GlassWeave
import GlassWeaveUIKit
import UIKit

/// The shelf study (GW-29): a frosted capsule that holds a large native title
/// and three native controls, over an iridescent procedural sky.
///
/// - **The background** (`study_shelf_fragment`): a blue sky, a soft rainbow
///   arc and six pebbles with their own thin-film colour. They drift a few
///   points around their rest positions over 48 seconds, so the frost's
///   pyramid is rebuilt about 30 times a second while they move (the cost the
///   proposal's budget table names).
/// - **The glass.** One capsule panel: an even frost, a thick bevel that
///   bends the pebbles' edges with a controlled six-tap dispersion at the
///   bevel only, and a legibility scrim that keeps the title at 4.5:1
///   whatever lies behind it (7:1 under Increase Contrast).
/// - **Native content.** A large title and three symbol buttons. Under Reduce
///   Motion the pebbles rest and nothing ticks.
final class ShelfStudyViewController: StudyViewController {
    override var kind: StudyKind { .shelf }
    override var studyStyle: UIUserInterfaceStyle { .dark }
    override var restTime: Double { 0 }

    private let shelfAnchor = UIView()
    private let titleLabel = UILabel()
    private let controls = UIStackView()
    private var buttons: [UIButton] = []

    private static let shelfHeight: CGFloat = 116

    override func buildContent(in content: UIView) {
        shelfAnchor.isUserInteractionEnabled = false
        shelfAnchor.isAccessibilityElement = false

        titleLabel.text = String(localized: "Open Air")
        titleLabel.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: .systemFont(ofSize: 36, weight: .bold, width: .standard))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.6
        titleLabel.textColor = .white
        titleLabel.accessibilityTraits.insert(.header)
        titleLabel.accessibilityIdentifier = "study.shelf.title"
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let items: [(symbol: String, label: String, id: String)] = [
            ("backward.fill", String(localized: "Previous"), "study.shelf.previous"),
            ("play.fill", String(localized: "Play"), "study.shelf.play"),
            ("forward.fill", String(localized: "Next"), "study.shelf.next"),
        ]
        buttons = items.map { item in
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: item.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
            configuration.baseForegroundColor = .white
            let button = UIButton(configuration: configuration)
            button.accessibilityLabel = item.label
            button.accessibilityIdentifier = item.id
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            return button
        }
        controls.axis = .horizontal
        controls.spacing = 2
        controls.alignment = .center
        buttons.forEach(controls.addArrangedSubview)
        controls.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [titleLabel, controls])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8

        for view in [shelfAnchor, row] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let safe = content.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            shelfAnchor.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 20),
            shelfAnchor.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -20),
            shelfAnchor.heightAnchor.constraint(equalToConstant: Self.shelfHeight),
            shelfAnchor.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -20),
            row.leadingAnchor.constraint(equalTo: shelfAnchor.leadingAnchor, constant: 34),
            row.trailingAnchor.constraint(equalTo: shelfAnchor.trailingAnchor, constant: -20),
            row.centerYAnchor.constraint(equalTo: shelfAnchor.centerYAnchor),
        ])
    }

    override func panels(at time: Double) -> [GlassPanel] {
        guard shelfAnchor.bounds.width > 0 else { return [] }
        var parameters = RefinedLook.lens(corner: 999, bezel: 28, thickness: 26, dark: false)
        parameters.lens.dispersion = 0.42
        parameters.lens.dispersionTaps = .sixTap
        parameters.tint = GlassTint(red: 0.86, green: 0.92, blue: 1.0, strength: 0.16)
        parameters.lighting.fresnel = 0.75
        parameters.lighting.specular = 0.62
        // An even frost, and a scrim over the title and the buttons.
        let textRect = frame(of: titleLabel).union(frame(of: controls)).insetBy(dx: -10, dy: -8)
        parameters.frost = GlassFrost(
            profile: .uniform, sigma: 6, grain: 0.04, thickness: 0.4, saturation: 1.12, brightness: 1.04
        ).legibility(text: .white, contrast: 3.5, rect: textRect, feather: 30)
        return [GlassPanel(frame: frame(of: shelfAnchor), parameters: parameters)]
    }

    override func backdropContent(at time: Double) -> (rects: [CGRect], time: Double, progress: Double) {
        // Whole hundredths of a second, so equal times give equal pictures.
        ([], (time * 100).rounded() / 100, 0)
    }
}
