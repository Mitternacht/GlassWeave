import GlassWeave
import GlassWeaveUIKit
import UIKit

/// The pearl study (GW-29): a light page with an embossed plate. A small
/// round button with a polished, prismatic chrome ring sits in a round well
/// pressed into the plate, beside a milky capsule that carries a native
/// label with a soft shadow.
///
/// - The plate and the well are part of the producer's background
///   (`study_pearl_fragment`), never panels.
/// - Two panels: the ring button (a `ring` lens, a refined prismatic finish
///   with a clear middle) and the milky pill (a light frost and a white
///   tint). Both throw a soft, short shadow away from the one light; the
///   shadows are compact so the panels' quads stay apart (rule 10).
/// - The script: the key light swings a few degrees to either side over 14
///   seconds, so the glints travel around the ring. Under Reduce Motion the
///   light rests at its centre.
///
/// Public GlassWeave API only. Light mode.
final class PearlStudyViewController: StudyViewController {
    override var kind: StudyKind { .pearl }
    override var studyStyle: UIUserInterfaceStyle { .light }
    override var restTime: Double { 0 }

    private let titleLabel = UILabel()
    private let plateAnchor = UIView()
    private let wellAnchor = UIView()
    private let buttonAnchor = UIView()
    private let pillAnchor = UIView()
    private let ringButton = UIButton(configuration: .plain())
    private let pillButton = UIButton(type: .custom)
    private let pillTitle = UILabel()
    private let pillDetail = UILabel()

    private static let buttonDiameter: CGFloat = 84
    private static let wellDiameter: CGFloat = 124
    private static let plateHeight: CGFloat = 200

    override func buildContent(in content: UIView) {
        titleLabel.text = String(localized: "Camera")
        titleLabel.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: .systemFont(ofSize: 34, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = UIColor(white: 0.14, alpha: 1)
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits.insert(.header)

        for anchor in [plateAnchor, wellAnchor, buttonAnchor, pillAnchor] {
            anchor.isUserInteractionEnabled = false
            anchor.isAccessibilityElement = false
            anchor.backgroundColor = .clear
        }

        // The ring button: a native button with a native symbol.
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "timer", withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .regular))
        configuration.baseForegroundColor = UIColor(white: 0.22, alpha: 1)
        ringButton.configuration = configuration
        ringButton.accessibilityLabel = String(localized: "Self-timer")
        ringButton.accessibilityIdentifier = "study.pearl.ring"
        ringButton.configurationUpdateHandler = { button in
            button.alpha = button.isHighlighted ? 0.6 : 1
        }

        // The capsule's label: a native label with a soft shadow, over a
        // button that carries the VoiceOver label.
        pillTitle.text = String(localized: "Self-timer")
        pillTitle.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 19, weight: .semibold))
        pillTitle.textColor = UIColor(white: 0.16, alpha: 1)
        pillDetail.text = String(localized: "3 seconds")
        pillDetail.font = .preferredFont(forTextStyle: .footnote)
        pillDetail.textColor = UIColor(white: 0.36, alpha: 1)
        for label in [pillTitle, pillDetail] {
            label.adjustsFontForContentSizeCategory = true
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.7
            label.isAccessibilityElement = false
            label.layer.shadowColor = UIColor(red: 0.16, green: 0.17, blue: 0.24, alpha: 1).cgColor
            label.layer.shadowOpacity = 0.30
            label.layer.shadowRadius = 3
            label.layer.shadowOffset = CGSize(width: 0, height: 2)
        }
        let labels = UIStackView(arrangedSubviews: [pillTitle, pillDetail])
        labels.axis = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.isUserInteractionEnabled = false
        pillButton.accessibilityLabel = String(localized: "Self-timer, 3 seconds")
        pillButton.accessibilityIdentifier = "study.pearl.pill"
        pillButton.accessibilityTraits = .button

        for view in [titleLabel, plateAnchor, wellAnchor, buttonAnchor, pillAnchor, ringButton, pillButton, labels] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let safe = content.safeAreaLayoutGuide
        let plateInset: CGFloat = 20
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            titleLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -76),

            plateAnchor.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: plateInset),
            plateAnchor.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -plateInset),
            plateAnchor.heightAnchor.constraint(equalToConstant: Self.plateHeight),
            plateAnchor.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -56),

            wellAnchor.leadingAnchor.constraint(equalTo: plateAnchor.leadingAnchor, constant: 24),
            wellAnchor.centerYAnchor.constraint(equalTo: plateAnchor.centerYAnchor),
            wellAnchor.widthAnchor.constraint(equalToConstant: Self.wellDiameter),
            wellAnchor.heightAnchor.constraint(equalToConstant: Self.wellDiameter),

            buttonAnchor.centerXAnchor.constraint(equalTo: wellAnchor.centerXAnchor),
            buttonAnchor.centerYAnchor.constraint(equalTo: wellAnchor.centerYAnchor),
            buttonAnchor.widthAnchor.constraint(equalToConstant: Self.buttonDiameter),
            buttonAnchor.heightAnchor.constraint(equalToConstant: Self.buttonDiameter),
            ringButton.centerXAnchor.constraint(equalTo: buttonAnchor.centerXAnchor),
            ringButton.centerYAnchor.constraint(equalTo: buttonAnchor.centerYAnchor),
            ringButton.widthAnchor.constraint(equalTo: buttonAnchor.widthAnchor),
            ringButton.heightAnchor.constraint(equalTo: buttonAnchor.heightAnchor),

            // The pill starts 90 points from the button's center, so the
            // two panels' shadows stay apart.
            pillAnchor.leadingAnchor.constraint(equalTo: buttonAnchor.centerXAnchor, constant: 100),
            pillAnchor.trailingAnchor.constraint(equalTo: plateAnchor.trailingAnchor, constant: -26),
            pillAnchor.centerYAnchor.constraint(equalTo: plateAnchor.centerYAnchor),
            pillAnchor.heightAnchor.constraint(equalToConstant: 72),
            pillButton.leadingAnchor.constraint(equalTo: pillAnchor.leadingAnchor),
            pillButton.trailingAnchor.constraint(equalTo: pillAnchor.trailingAnchor),
            pillButton.topAnchor.constraint(equalTo: pillAnchor.topAnchor),
            pillButton.bottomAnchor.constraint(equalTo: pillAnchor.bottomAnchor),
            labels.leadingAnchor.constraint(equalTo: pillAnchor.leadingAnchor, constant: 24),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: pillAnchor.trailingAnchor, constant: -16),
            labels.centerYAnchor.constraint(equalTo: pillAnchor.centerYAnchor),
        ])
    }

    // MARK: Panels

    private var lightAzimuth: Double {
        // Eight degrees to either side, one swing per 14 seconds, in half
        // degrees: the picture changes about seven times a second at most
        // (the script ticks 30 times), not on every tick.
        RefinedLook.azimuth + (16 * sin(2 * .pi * scriptTime / 14)).rounded() / 2
    }

    /// A compact, soft shadow: one drop and a faint contact line, away from the
    /// light. Its reach is 25 points, so two panels 50 points apart keep their
    /// quads apart.
    private func shadow() -> GlassGrounding {
        let ink = GlassGrounding.Color(red: 0.16, green: 0.17, blue: 0.26)
        return GlassGrounding(
            drop: .init(offset: 5, blur: 12, spread: -2, opacity: 0.22, color: ink),
            contact: .init(width: 1, opacity: 0.09, color: ink),
            lightAzimuth: RefinedLook.azimuth
        )
    }

    override func panels(at time: Double) -> [GlassPanel] {
        guard plateAnchor.bounds.width > 0 else { return [] }
        // ENHANCE: the polished chrome ring (stripes and small prismatic
        // glints that turn with the light).
        var ring = RefinedLook.chromeRing(diameter: Double(Self.buttonDiameter), azimuth: lightAzimuth)
        ring.grounding = shadow()

        // The milky capsule: a light frost over the plate, a white tint, and
        // the refined rim.
        var pill = RefinedLook.panel(corner: 999, bezel: 16, dark: false)
        pill.tint = GlassTint(red: 1, green: 1, blue: 1, strength: 0.55)
        pill.frost = GlassFrost(profile: .uniform, sigma: 6, grain: 0.03, saturation: 1, brightness: 1.02)
        pill.lighting = RefinedLook.enhancedLighting(dark: false)
        pill.lighting.key.azimuth = lightAzimuth
        pill.grounding = shadow()

        return [
            GlassPanel(frame: frame(of: buttonAnchor), parameters: ring),
            GlassPanel(frame: frame(of: pillAnchor), parameters: pill),
        ]
    }

    override func backdropContent(at time: Double) -> (rects: [CGRect], time: Double, progress: Double) {
        ([frame(of: plateAnchor), frame(of: wellAnchor)], 0, 0)
    }
}
