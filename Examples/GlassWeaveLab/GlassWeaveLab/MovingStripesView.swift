import UIKit

/// A simple moving backdrop for the native-glass reference: diagonal stripes
/// that slide back and forth with a Core Animation animation.
///
/// It uses no Metal, so the native region's GPU work is the system's own.
/// With Reduce Motion on, the stripes stay still.
final class MovingStripesView: UIView {
    private let stripes = CAGradientLayer()
    private static let stripeCount = 12
    private static let animationKey = "lab.stripes.slide"
    /// The width the running animation was built for.
    private var animatedWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        stripes.startPoint = CGPoint(x: 0, y: 0)
        stripes.endPoint = CGPoint(x: 1, y: 0.35)
        // Hard color stops: each stripe's color starts and ends at the same
        // location as its neighbor's.
        stripes.locations = (0..<Self.stripeCount).flatMap { index -> [NSNumber] in
            let start = Double(index) / Double(Self.stripeCount)
            let end = Double(index + 1) / Double(Self.stripeCount)
            return [NSNumber(value: start), NSNumber(value: end)]
        }
        layer.addSublayer(stripes)
        updateColors()

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.updateColors()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(reduceMotionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Twice as wide as the view so a slide of one width never shows an edge.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stripes.frame = CGRect(x: 0, y: 0, width: bounds.width * 2, height: bounds.height)
        CATransaction.commit()
        if bounds.width != animatedWidth {
            updateAnimation()
        }
    }

    @objc private func reduceMotionChanged() {
        updateAnimation()
    }

    private func updateColors() {
        let palette: [UIColor] = [.systemTeal, .systemIndigo, .systemOrange]
        stripes.colors = (0..<Self.stripeCount).flatMap { index -> [CGColor] in
            let color = palette[index % palette.count].resolvedColor(with: traitCollection).cgColor
            return [color, color]
        }
    }

    private func updateAnimation() {
        stripes.removeAnimation(forKey: Self.animationKey)
        animatedWidth = bounds.width
        guard bounds.width > 0, !UIAccessibility.isReduceMotionEnabled else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = 0
        slide.toValue = -bounds.width
        slide.duration = 6
        slide.autoreverses = true
        slide.repeatCount = .infinity
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Keep running across app background/foreground transitions.
        slide.isRemovedOnCompletion = false
        stripes.add(slide, forKey: Self.animationKey)
    }
}
