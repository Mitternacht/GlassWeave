import GlassWeave
import GlassWeaveUIKit
import UIKit

/// The vessel study (GW-29): thick, smoky glass holding a calm luminous
/// liquid, on a dark stage.
///
/// - **The glass.** Two vessels, each one panel: a large organic vessel (a GW-26
///   blob shell) holding a **gel** that wets its lower and right walls, and a
///   small tall vessel with a **level** liquid (a glossy surface with a meniscus
///   at the wall). The shells are the refined thick lens (a squircle bevel that
///   magnifies the stage's edge, controlled dispersion, the thin lit-side rim)
///   with a smoky tint, so the glass itself is nearly clear and the liquid is the
///   only bright thing.
/// - **The liquid.** One warm ramp (deep amber, orange, pale gold) on a curved
///   body (dark amber toward the walls, a lit side, a soft specular streak),
///   two or three layered sheets with thin caustic edges, a few tiny bubbles and
///   a warm glow on the wall. The restraint is the point: the picture should
///   read as a premium material, not as a gel toy.
/// - **Native controls.** A title, a "Liquid level" slider and a "Nudge"
///   button for the small vessel. The level moves its surface and, a little,
///   the light it throws on the table; Nudge starts a damped slosh (``GlassFillSlosh``) that
///   the 30 Hz script tick steps until it settles. Under Reduce Motion Nudge is
///   disabled and the liquid holds still.
/// - **The clock.** The script drives the slosh; the surface's own effect
///   clock moves the bubbles and the gel's slow wobble (a pinned
///   `-lab.studyTime` holds it still for a capture).
///
/// The stage is a still picture (`study_vessel_fragment`): it is drawn again
/// only when the layout or the level changes.
final class VesselStudyViewController: StudyViewController {
    override var kind: StudyKind { .vessel }
    override var studyStyle: UIUserInterfaceStyle { .dark }
    override var restTime: Double { 0 }
    override var usesEffectClock: Bool { true }

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let heroAnchor = UIView()
    private let tubeAnchor = UIView()
    private let levelCaption = UILabel()
    private let levelValue = UILabel()
    private let levelSlider = UISlider()
    private let nudgeButton = UIButton(configuration: .glass())

    private var level = 0.58
    private var slosh = GlassFillSlosh(period: 0.9, dampingRatio: 0.2)
    private var sloshTime: Double?

    // MARK: Content

    override func buildContent(in content: UIView) {
        titleLabel.text = String(localized: "Amber")
        titleLabel.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: .systemFont(ofSize: 34, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits.insert(.header)
        titleLabel.accessibilityIdentifier = "study.vessel.title"

        subtitleLabel.text = String(localized: "Liquid in thick glass")
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = UIColor(white: 1, alpha: 0.62)
        subtitleLabel.numberOfLines = 0

        for anchor in [heroAnchor, tubeAnchor] {
            anchor.isUserInteractionEnabled = false
            anchor.isAccessibilityElement = false
        }

        levelCaption.text = String(localized: "Liquid level")
        levelCaption.font = .preferredFont(forTextStyle: .subheadline)
        levelCaption.adjustsFontForContentSizeCategory = true
        levelCaption.textColor = UIColor(white: 1, alpha: 0.78)
        levelCaption.isAccessibilityElement = false
        levelValue.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular)
        levelValue.textColor = UIColor(white: 1, alpha: 0.78)
        levelValue.textAlignment = .right
        levelValue.isAccessibilityElement = false

        levelSlider.minimumValue = 0.12
        levelSlider.maximumValue = 0.92
        levelSlider.value = Float(level)
        levelSlider.minimumTrackTintColor = UIColor(red: 1.0, green: 0.62, blue: 0.22, alpha: 1)
        levelSlider.accessibilityLabel = String(localized: "Liquid level")
        levelSlider.accessibilityIdentifier = "study.vessel.level"
        levelSlider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            level = (Double(levelSlider.value) * 100).rounded() / 100
            refresh()
        }, for: .valueChanged)

        nudgeButton.configuration?.title = String(localized: "Nudge")
        nudgeButton.configuration?.baseForegroundColor = .white
        nudgeButton.accessibilityIdentifier = "study.vessel.nudge"
        nudgeButton.addAction(UIAction { [weak self] _ in self?.nudge() }, for: .primaryActionTriggered)

        let captionRow = UIStackView(arrangedSubviews: [levelCaption, levelValue])
        captionRow.axis = .horizontal
        captionRow.spacing = 8
        let controls = UIStackView(arrangedSubviews: [captionRow, levelSlider, nudgeButton])
        controls.axis = .vertical
        controls.spacing = 14
        controls.alignment = .fill

        for view in [titleLabel, subtitleLabel, heroAnchor, tubeAnchor, controls] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let safe = content.safeAreaLayoutGuide
        let heroWidth = heroAnchor.widthAnchor.constraint(equalTo: safe.widthAnchor, constant: -52)
        heroWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            titleLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -76),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -24),

            heroAnchor.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            heroAnchor.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 26),
            heroAnchor.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 26),
            heroAnchor.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            heroWidth,
            heroAnchor.heightAnchor.constraint(equalTo: heroAnchor.widthAnchor, multiplier: 1.10),

            tubeAnchor.trailingAnchor.constraint(equalTo: heroAnchor.trailingAnchor),
            tubeAnchor.topAnchor.constraint(equalTo: heroAnchor.bottomAnchor, constant: 28),
            tubeAnchor.widthAnchor.constraint(equalTo: heroAnchor.widthAnchor, multiplier: 0.30),
            tubeAnchor.heightAnchor.constraint(equalTo: tubeAnchor.widthAnchor, multiplier: 1.35),

            controls.leadingAnchor.constraint(equalTo: heroAnchor.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: tubeAnchor.leadingAnchor, constant: -26),
            controls.centerYAnchor.constraint(equalTo: tubeAnchor.centerYAnchor),
        ])
        updateControls()
    }

    private func updateControls() {
        levelValue.text = String(format: "%d%%", Int((level * 100).rounded()))
        levelSlider.accessibilityValue = levelValue.text
        nudgeButton.isEnabled = !reduceMotion
    }

    // MARK: Script

    private func nudge() {
        // An app that honors Reduce Motion does not slosh the liquid.
        guard !reduceMotion else { return }
        try? slosh.nudge(velocity: -900)
        refresh()
    }

    /// Steps the slosh by the script time that has passed, in at most 0.1 s
    /// steps (the spring itself steps at 1/240 s).
    override func applyScript(at time: Double) {
        if let last = sloshTime, time > last, !slosh.isSettled {
            try? slosh.advance(by: min(time - last, 0.1))
        }
        sloshTime = time
        updateControls()
    }

    // MARK: Panels

    private static func color(_ red: Double, _ green: Double, _ blue: Double) -> GlassFill.Color {
        GlassFill.Color(red: red, green: green, blue: blue)
    }

    /// Thick, smoky glass: the refined lens with a dark warm tint, so the body
    /// is nearly clear and dark and the rim is the thin lit-side line.
    private static func shell(corner: Double, bezel: Double, thickness: Double) -> GlassParameters {
        var parameters = RefinedLook.lens(corner: corner, bezel: bezel, thickness: thickness, dark: true)
        parameters.tint = GlassTint(red: 0.08, green: 0.07, blue: 0.07, strength: 0.34)
        parameters.lens.dispersion = 0.10
        return parameters
    }

    override func panels(at time: Double) -> [GlassPanel] {
        guard heroAnchor.bounds.width > 0 else { return [] }

        // The large vessel: an organic shell, a smooth union of two round
        // masses and a soft box (a GW-26 blob), holding a gel that sits low in
        // it and wets the lower and right walls, so the thick glass bends its
        // edge there. Frame units: 1 is half the frame's shorter side.
        var hero = Self.shell(corner: 999, bezel: 34, thickness: 30)
        hero.shape = .blob(GlassBlob(
            primitives: [
                .circle(center: CGPoint(x: -0.16, y: -0.14), radius: 0.80),
                .circle(center: CGPoint(x: 0.20, y: 0.20), radius: 0.76),
                .box(center: CGPoint(x: 0.0, y: 0.34), halfSize: CGSize(width: 0.80, height: 0.66), cornerRadius: 0.55, rotation: -3),
            ],
            smoothness: 0.55
        ))
        hero.fill = GlassFill(
            region: .gel(.blob(GlassBlob(
                primitives: [
                    .box(center: CGPoint(x: 0.12, y: 0.46), halfSize: CGSize(width: 0.92, height: 0.58), cornerRadius: 0.50, rotation: -4),
                    .circle(center: CGPoint(x: 0.34, y: 0.02), radius: 0.56),
                ],
                smoothness: 0.62, wobble: GlassBlob.Wobble(amplitude: 0.008, speed: 0.5)
            ))),
            wallThickness: 8,
            colors: [Self.color(0.30, 0.05, 0.01), Self.color(1.00, 0.40, 0.05), Self.color(1.00, 0.72, 0.32)],
            emission: 0.85, absorption: 0.7,
            sheets: GlassFill.Sheets(count: 3, spacing: 16, edge: 0.45, wobble: 0.6),
            wallLine: 0.45,
            bubbles: GlassFill.Bubbles(count: 6, size: 2.6, speed: 0.6, seed: 7),
            gloss: 0.7
        )

        // The small vessel: a level liquid that the slider fills and Nudge
        // sloshes.
        var tube = Self.shell(corner: 36, bezel: 20, thickness: 20)
        tube.fill = GlassFill(
            region: .level(level: level, tilt: slosh.tilt),
            wallThickness: 5,
            colors: [Self.color(0.30, 0.04, 0.02), Self.color(0.95, 0.26, 0.05), Self.color(1.00, 0.58, 0.26)],
            emission: 0.85, absorption: 0.7,
            sheets: GlassFill.Sheets(count: 1, spacing: 14, edge: 0.3, wobble: 0.2),
            wallLine: 0.4,
            bubbles: GlassFill.Bubbles(count: 3, size: 1.8, speed: 0.6, seed: 21),
            // A swinging surface ripples; a still one barely does.
            surface: GlassFill.Surface(
                waveAmplitude: 0.5 + 2.2 * slosh.agitation, wavelength: 60, waveSpeed: 0.8, meniscus: 3
            )
        )
        return [
            GlassPanel(frame: frame(of: heroAnchor), parameters: hero),
            GlassPanel(frame: frame(of: tubeAnchor), parameters: tube),
        ]
    }

    override func backdropContent(at time: Double) -> (rects: [CGRect], time: Double, progress: Double) {
        ([frame(of: heroAnchor), frame(of: tubeAnchor)], 0, level)
    }
}
