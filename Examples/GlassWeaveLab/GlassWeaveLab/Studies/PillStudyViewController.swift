import GlassWeave
import GlassWeaveUIKit
import UIKit

/// The pill study (GW-29): a wide, thick lens pill over a soft field of large
/// fuzzy spheres, with a dome button inlaid at its end.
///
/// - **The glass.** One capsule panel: a squircle bevel that magnifies the
///   spheres behind its edge (a thick lens, with controlled dispersion at the
///   bevel only), a lightly frosted body, the refined top specular streak, and
///   a four-stop pooled glow along the bottom inside (a `GlassLight` band that
///   flows slowly). The dome is an **inlay** of the same panel (GW-22): the same
///   piece of glass, in one panel and one pass, not a second panel.
/// - **Native content.** A leaf symbol, the elapsed time and a pause button
///   that sits on the dome. The time carries a legibility scrim (4.5:1).
/// - **The script.** The elapsed time counts up in whole seconds from 12:04,
///   and the glow's palette drifts sideways with it. Pause stops both; the
///   script time at launch (`-lab.studyTime`) sets what a capture shows.
///   Under Reduce Motion the time rests at its first value and the glow holds
///   still.
///
/// The background is a still picture (`study_pill_fragment`): it is drawn once
/// and then not at all.
final class PillStudyViewController: StudyViewController {
    override var kind: StudyKind { .pill }
    override var studyStyle: UIUserInterfaceStyle { .dark }
    override var restTime: Double { 0 }

    private let titleLabel = UILabel()
    private let pillAnchor = UIView()
    private let domeAnchor = UIView()
    private let leafView = UIImageView()
    private let timeLabel = UILabel()
    private let pauseButton = UIButton(configuration: .plain())

    private var isPaused = false
    private var pausedAt: Double?
    private var pausedTotal = 0.0

    private static let pillHeight: CGFloat = 108
    private static let domeDiameter: CGFloat = 76
    private static let firstSecond = 724.0    // 12:04

    /// The seconds of the session at script time `time`, which stand still
    /// while paused.
    private func elapsed(at time: Double) -> Double {
        (pausedAt ?? time) - pausedTotal
    }

    override func buildContent(in content: UIView) {
        titleLabel.text = String(localized: "Focus")
        titleLabel.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: .systemFont(ofSize: 34, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits.insert(.header)

        pillAnchor.isUserInteractionEnabled = false
        pillAnchor.isAccessibilityElement = false
        domeAnchor.isUserInteractionEnabled = false
        domeAnchor.isAccessibilityElement = false

        leafView.image = UIImage(systemName: "leaf.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .regular))
        leafView.tintColor = UIColor(white: 1, alpha: 0.96)
        leafView.contentMode = .scaleAspectFit
        leafView.isAccessibilityElement = false

        timeLabel.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: .monospacedDigitSystemFont(ofSize: 46, weight: .light))
        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.adjustsFontSizeToFitWidth = true
        timeLabel.minimumScaleFactor = 0.6
        timeLabel.textColor = .white
        timeLabel.textAlignment = .center
        timeLabel.accessibilityIdentifier = "study.pill.time"
        timeLabel.accessibilityTraits.insert(.updatesFrequently)
        timeLabel.accessibilityLabel = String(localized: "Elapsed time")

        pauseButton.accessibilityIdentifier = "study.pill.pause"
        pauseButton.addAction(UIAction { [weak self] _ in self?.togglePause() }, for: .primaryActionTriggered)
        updatePauseButton()

        for view in [titleLabel, pillAnchor, domeAnchor, leafView, timeLabel, pauseButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let safe = content.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            titleLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -76),

            pillAnchor.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 22),
            pillAnchor.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -22),
            pillAnchor.heightAnchor.constraint(equalToConstant: Self.pillHeight),
            pillAnchor.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -30),

            domeAnchor.trailingAnchor.constraint(equalTo: pillAnchor.trailingAnchor, constant: -(Self.pillHeight - Self.domeDiameter) / 2),
            domeAnchor.centerYAnchor.constraint(equalTo: pillAnchor.centerYAnchor),
            domeAnchor.widthAnchor.constraint(equalToConstant: Self.domeDiameter),
            domeAnchor.heightAnchor.constraint(equalToConstant: Self.domeDiameter),
            pauseButton.centerXAnchor.constraint(equalTo: domeAnchor.centerXAnchor),
            pauseButton.centerYAnchor.constraint(equalTo: domeAnchor.centerYAnchor),
            pauseButton.widthAnchor.constraint(equalTo: domeAnchor.widthAnchor),
            pauseButton.heightAnchor.constraint(equalTo: domeAnchor.heightAnchor),

            leafView.leadingAnchor.constraint(equalTo: pillAnchor.leadingAnchor, constant: 30),
            leafView.centerYAnchor.constraint(equalTo: pillAnchor.centerYAnchor),
            leafView.widthAnchor.constraint(equalToConstant: 32),

            timeLabel.leadingAnchor.constraint(equalTo: leafView.trailingAnchor, constant: 10),
            timeLabel.trailingAnchor.constraint(equalTo: domeAnchor.leadingAnchor, constant: -10),
            timeLabel.centerYAnchor.constraint(equalTo: pillAnchor.centerYAnchor, constant: -2),
        ])
    }

    // MARK: Script

    private func togglePause() {
        if let since = pausedAt {
            pausedTotal += scriptTime - since
            pausedAt = nil
        } else {
            pausedAt = scriptTime
        }
        isPaused = pausedAt != nil
        updatePauseButton()
        refresh()
    }

    private func updatePauseButton() {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: isPaused ? "play.fill" : "pause.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        )
        configuration.baseForegroundColor = .white
        pauseButton.configuration = configuration
        pauseButton.accessibilityLabel = isPaused ? String(localized: "Resume") : String(localized: "Pause")
    }

    override func applyScript(at time: Double) {
        let seconds = Int(Self.firstSecond + elapsed(at: time).rounded(.down))
        let text = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        if timeLabel.text != text {
            timeLabel.text = text
            timeLabel.accessibilityValue = text
        }
    }

    // MARK: Panels

    override func panels(at time: Double) -> [GlassPanel] {
        guard pillAnchor.bounds.width > 0 else { return [] }
        let frame = frame(of: pillAnchor)
        // ENHANCE: a thicker lens (the bevel bends what is behind its edge
        // harder), the enhanced rim, and a soft drop shadow.
        var parameters = RefinedLook.enhancedLens(corner: 999, bezel: 32, thickness: 42, dispersion: 0.7, dark: true)
        let domeX = (frame.width - Self.pillHeight) / 2
        parameters.lens.inlays = [
            GlassLens.Inlay(
                x: isRightToLeft ? -domeX : domeX, y: 0, radius: Double(Self.domeDiameter) / 2 + 2, height: 20,
                profile: .dome, rimLine: 0.8
            )
        ]
        parameters.tint = GlassTint(red: 0.70, green: 0.76, blue: 0.86, strength: 0.07)

        // A light frost, so the spheres behind the middle soften while the
        // bevel stays crisp and magnified; a scrim keeps the time at 4.5:1.
        parameters.frost = GlassFrost(
            profile: .uniform, sigma: 2.6, grain: 0.04, thickness: 0.5, saturation: 1.05, brightness: 1
        ).legibility(text: .white, contrast: 3.0, rect: self.frame(of: timeLabel).insetBy(dx: -12, dy: -6), feather: 26)

        // The pooled glow: four stops along the bottom edge, flowing slowly
        // while the session runs (one turn of the palette per 64 seconds), in quarter seconds so the panel
        // changes four times a second, not on every tick.
        let sky = GlassLight.Stop(red: 0.16, green: 0.62, blue: 1.0)
        let violet = GlassLight.Stop(red: 0.50, green: 0.32, blue: 1.0)
        let rose = GlassLight.Stop(red: 1.0, green: 0.26, blue: 0.62)
        let amber = GlassLight.Stop(red: 1.0, green: 0.42, blue: 0.46)
        parameters.light = GlassLight(
            emitters: [
                GlassLight.Emitter(placement: .band(angle: 180, reach: 1.7), colors: [sky, violet, rose, amber], intensity: 0.7, flow: 1)
            ],
            composite: .paint, centerFade: 0.6, piping: 0.45, body: 1, speed: 1, timeOffset: (elapsed(at: time) * 4).rounded() / 4
        )
        parameters.lighting.key.azimuth = RefinedLook.azimuth
        return [GlassPanel(frame: frame, parameters: parameters)]
    }

    override func backdropContent(at time: Double) -> (rects: [CGRect], time: Double, progress: Double) {
        ([], 0, 0)
    }
}
