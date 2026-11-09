import GlassWeave
import GlassWeaveUIKit
import UIKit

/// A text plate on the versus screen: white text on a dark rounded plate, so
/// it reads over the colorful backdrop in both appearances. It is one
/// accessibility element that carries all its lines.
final class VersusPlate: UIView {
    struct Line {
        let text: String
        let style: UIFont.TextStyle
        let isBold: Bool
    }

    private let stack = UIStackView()

    init(lines: [Line], isHeader: Bool = false) {
        super.init(frame: .zero)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        stack.axis = .vertical
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        for line in lines {
            let label = UILabel()
            label.text = line.text
            label.numberOfLines = 0
            label.textColor = .white
            label.adjustsFontForContentSizeCategory = true
            label.font = Self.font(line)
            label.isAccessibilityElement = false
            stack.addArrangedSubview(label)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            // The plate may be taller than its text, to match its twin.
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])
        isAccessibilityElement = true
        accessibilityLabel = lines.map(\.text).joined(separator: ". ")
        accessibilityTraits = isHeader ? .header : .staticText
        setOpaque(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func font(_ line: Line) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: line.style)
        guard line.isBold else { return base }
        return UIFontMetrics(forTextStyle: line.style).scaledFont(for: .systemFont(ofSize: base.pointSize, weight: .semibold))
    }

    /// An opaque plate for Reduce Transparency and Increase Contrast.
    func setOpaque(_ opaque: Bool) {
        backgroundColor = UIColor(white: 0.07, alpha: opaque ? 0.97 : 0.68)
    }
}

/// One row of the versus screen on one side: a title, the capsule, and what
/// this side does. Both sides build the same row from the same case, so the
/// layouts match; the screen ties the heights of the twins.
///
/// The capsule (``panel``) is where the glass is. On the native side it is
/// the glass itself, an ``EnhancedNativeGlassView`` (Apple's `UIGlassEffect`
/// with its one tint and a GlassWeave rim and halo around it); on the
/// GlassWeave side it is a plain placeholder whose frame the screen gives to
/// the glass surface behind it. A native button with a VoiceOver label fills
/// each capsule.
final class VersusRowView: UIView {
    enum Side {
        case native
        case weave

        var name: String {
            switch self {
            case .native: String(localized: "Apple glass")
            case .weave: String(localized: "GlassWeave glass")
            }
        }

        var identifier: String {
            switch self {
            case .native: "native"
            case .weave: "weave"
            }
        }
    }

    /// Space between the slot's sides and the capsule: the halo, and a few
    /// points, so it is never cut off.
    static let horizontalMargin = CGFloat(VersusCase.halo) + 8
    static let verticalMargin = CGFloat(VersusCase.halo) + 6

    let versusCase: VersusCase
    let side: Side
    let titlePlate: VersusPlate
    let captionPlate: VersusPlate
    /// The capsule's view: the native glass, or the placeholder.
    let panel: UIView
    /// The native control that fills the capsule.
    let button = UIButton(configuration: .plain())
    /// The native glass, on the native side.
    let nativeHost: EnhancedNativeGlassView?

    init(versusCase: VersusCase, side: Side, onTap: @escaping () -> Void) {
        self.versusCase = versusCase
        self.side = side
        titlePlate = VersusPlate(lines: [.init(text: versusCase.title, style: .subheadline, isBold: true)], isHeader: true)
        let caption = side == .native ? versusCase.nativeCaption : versusCase.weaveCaption
        captionPlate = VersusPlate(lines: [.init(text: caption, style: .caption1, isBold: false)])
        switch side {
        case .native:
            let host = EnhancedNativeGlassView()
            host.glass.cornerConfiguration = .capsule()
            host.glass.configuration = NativeGlassView.Configuration(
                tintColor: versusCase.native.tint, isInteractive: true, style: versusCase.native.style
            )
            // The glow is finite, so the view never rejects it. A row without
            // one shows the genuine `UIGlassEffect` alone.
            if let glow = versusCase.native.glow {
                try? host.setGlow(glow)
            }
            if let override = LabViewController.accessibilitySettingsOverride {
                host.accessibilitySettingsSource = .fixed(override)
            }
            nativeHost = host
            panel = host
        case .weave:
            nativeHost = nil
            panel = UIView()
        }
        super.init(frame: .zero)

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: versusCase.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .medium)
        )
        configuration.baseForegroundColor = .label
        button.configuration = configuration
        button.accessibilityLabel = "\(versusCase.title), \(side.name)"
        button.accessibilityIdentifier = "versus.\(side.identifier).\(versusCase.id)"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addAction(UIAction { _ in onTap() }, for: .primaryActionTriggered)
        let buttonParent = nativeHost?.glass.contentView ?? panel
        buttonParent.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: buttonParent.topAnchor),
            button.bottomAnchor.constraint(equalTo: buttonParent.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: buttonParent.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: buttonParent.trailingAnchor),
        ])

        // The slot gives the capsule its halo's room.
        let slot = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(panel)
        let leading = panel.leadingAnchor.constraint(equalTo: slot.leadingAnchor, constant: Self.horizontalMargin)
        let trailing = panel.trailingAnchor.constraint(equalTo: slot.trailingAnchor, constant: -Self.horizontalMargin)
        leading.priority = .required - 1
        trailing.priority = .required - 1
        NSLayoutConstraint.activate([
            leading, trailing,
            panel.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            panel.heightAnchor.constraint(equalToConstant: versusCase.height),
            slot.heightAnchor.constraint(equalToConstant: versusCase.height + 2 * Self.verticalMargin),
        ])

        let column = UIStackView(arrangedSubviews: [titlePlate, slot, captionPlate])
        column.axis = .vertical
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
